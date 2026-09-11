use std::collections::HashSet;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, OnceLock};

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, lookup_host};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::accept_hdr_async;
use tokio_tungstenite::tungstenite::error::ProtocolError;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::{StatusCode, header};
use tokio_tungstenite::tungstenite::{Error, Message, Result};
use tracing::{info, warn};

const RELAY_BUFFER: usize = 16 * 1024;
const SUBPROTOCOL: &str = "sec-websocket-protocol";

/// Targets the proxy may connect to, compared as exact `host:port` strings.
///
/// An empty list permits every target, as upstream wsProxy does.
#[derive(Debug, Default)]
pub struct AllowList(HashSet<String>);

impl AllowList {
    pub fn new(targets: &str) -> Self {
        Self(
            targets
                .split(',')
                .map(str::trim)
                .filter(|target| !target.is_empty())
                .map(str::to_owned)
                .collect(),
        )
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn permits(&self, target: &str) -> bool {
        self.0.is_empty() || self.0.contains(target)
    }
}

pub async fn serve(listener: TcpListener, allow: Arc<AllowList>) {
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) => {
                warn!(%error, "accept failed");
                continue;
            }
        };

        let allow = allow.clone();
        tokio::spawn(async move {
            if let Err(error) = handle(stream, peer, allow).await {
                warn!(%peer, %error, "connection failed");
            }
        });
    }
}

#[allow(
    clippy::result_large_err,
    reason = "signature imposed by tungstenite::Callback"
)]
async fn handle(stream: TcpStream, peer: SocketAddr, allow: Arc<AllowList>) -> Result<()> {
    stream.set_nodelay(true)?;

    let requested: Arc<OnceLock<String>> = Arc::default();
    let slot = requested.clone();
    let handshake = accept_hdr_async(stream, move |request: &Request, response: Response| {
        handshake(request, response, &allow, peer, &slot)
    })
    .await;

    let websocket = match handshake {
        Ok(websocket) => websocket,
        Err(Error::Http(_)) => return Ok(()),
        Err(error) => return Err(error),
    };

    let Some(target) = requested.get() else {
        return Ok(());
    };

    let address = resolve_ipv4(target).await?;
    let upstream = TcpStream::connect(address).await?;
    upstream.set_nodelay(true)?;
    info!(%peer, %target, %address, "connection accepted");

    let outcome = relay(websocket, upstream).await;
    match outcome {
        Ok(()) => info!(%peer, %target, "connection closed"),
        Err(error) if is_abrupt_disconnect(&error) => {
            info!(%peer, %target, %error, "connection dropped");
        }
        Err(error) => return Err(error),
    }
    Ok(())
}

#[allow(
    clippy::result_large_err,
    reason = "signature imposed by tungstenite::Callback"
)]
fn handshake(
    request: &Request,
    mut response: Response,
    allow: &AllowList,
    peer: SocketAddr,
    slot: &OnceLock<String>,
) -> std::result::Result<Response, ErrorResponse> {
    let path = request.uri().path();
    let target = path.strip_prefix('/').unwrap_or(path);

    if !allow.permits(target) {
        warn!(%peer, %target, "target rejected");
        return Err(unauthorized());
    }

    if let Some(offered) = request
        .headers()
        .get(SUBPROTOCOL)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse().ok())
    {
        response.headers_mut().insert(SUBPROTOCOL, offered);
    }

    let _ = slot.set(target.to_owned());
    Ok(response)
}

fn unauthorized() -> ErrorResponse {
    let body = "Unauthorized";
    let mut response = ErrorResponse::new(Some(body.to_owned()));
    *response.status_mut() = StatusCode::UNAUTHORIZED;
    response
        .headers_mut()
        .insert(header::CONNECTION, "close".parse().unwrap());
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, body.len().into());
    response
}

async fn resolve_ipv4(target: &str) -> io::Result<SocketAddr> {
    lookup_host(target)
        .await?
        .find(SocketAddr::is_ipv4)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                format!("no IPv4 address for {target}"),
            )
        })
}

/// Relays bytes verbatim until either side goes away, then tears down both.
async fn relay(websocket: WebSocketStream<TcpStream>, upstream: TcpStream) -> Result<()> {
    let (mut socket_sink, mut socket_stream) = websocket.split();
    let (mut upstream_reader, mut upstream_writer) = upstream.into_split();

    let to_upstream = async {
        while let Some(message) = socket_stream.next().await {
            match message? {
                Message::Binary(data) => upstream_writer.write_all(&data).await?,
                Message::Text(data) => upstream_writer.write_all(data.as_bytes()).await?,
                Message::Close(_) => break,
                _ => {}
            }
        }
        upstream_writer.shutdown().await?;
        Ok(())
    };

    let to_socket = async {
        let mut buffer = vec![0u8; RELAY_BUFFER];
        loop {
            let read = upstream_reader.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            socket_sink
                .send(Message::binary(buffer[..read].to_vec()))
                .await?;
        }
        socket_sink.close().await?;
        Ok(())
    };

    tokio::select! {
        outcome = to_upstream => outcome,
        outcome = to_socket => outcome,
    }
}

fn is_abrupt_disconnect(error: &Error) -> bool {
    match error {
        Error::ConnectionClosed | Error::AlreadyClosed => true,
        Error::Protocol(protocol) => {
            matches!(protocol, ProtocolError::ResetWithoutClosingHandshake)
        }
        Error::Io(io) => matches!(
            io.kind(),
            io::ErrorKind::ConnectionReset | io::ErrorKind::BrokenPipe
        ),
        _ => false,
    }
}
