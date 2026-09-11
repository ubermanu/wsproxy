use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error, Message};
use wsproxy::{AllowList, serve};

const TIMEOUT: Duration = Duration::from_secs(5);

async fn start_proxy(allow: &str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(serve(listener, Arc::new(AllowList::new(allow))));
    address.to_string()
}

async fn start_echo() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0u8; 1024];
                while let Ok(read) = stream.read(&mut buffer).await {
                    if read == 0 || stream.write_all(&buffer[..read]).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    address.to_string()
}

#[tokio::test]
async fn rejects_target_outside_allowlist() {
    let proxy = start_proxy("127.0.0.1:1").await;

    let error = connect_async(format!("ws://{proxy}/127.0.0.1:9"))
        .await
        .unwrap_err();

    match error {
        Error::Http(response) => assert_eq!(response.status(), 401),
        other => panic!("expected an HTTP error, got {other}"),
    }
}

#[tokio::test]
async fn relays_binary_in_both_directions() {
    let echo = start_echo().await;
    let proxy = start_proxy(&echo).await;
    let payload = vec![0x00, 0x64, 0xff, 0x0a, 0x1b];

    let (mut client, _) = connect_async(format!("ws://{proxy}/{echo}")).await.unwrap();
    client.send(Message::binary(payload.clone())).await.unwrap();
    let echoed = tokio::time::timeout(TIMEOUT, client.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    assert_eq!(echoed, Message::binary(payload));
}

#[tokio::test]
async fn permits_any_target_without_an_allowlist() {
    let echo = start_echo().await;
    let proxy = start_proxy("").await;

    let (mut client, _) = connect_async(format!("ws://{proxy}/{echo}")).await.unwrap();
    client.send(Message::binary(vec![0x42])).await.unwrap();
    let echoed = tokio::time::timeout(TIMEOUT, client.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    assert_eq!(echoed, Message::binary(vec![0x42]));
}

#[tokio::test]
async fn closing_the_tcp_side_closes_the_websocket() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap().to_string();
    tokio::spawn(async move { drop(listener.accept().await.unwrap()) });
    let proxy = start_proxy(&target).await;

    let (mut client, _) = connect_async(format!("ws://{proxy}/{target}"))
        .await
        .unwrap();
    let closing = tokio::time::timeout(TIMEOUT, client.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    assert!(closing.is_close());
    assert!(client.next().await.is_none());
}

#[tokio::test]
async fn closing_the_websocket_closes_the_tcp_side() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap().to_string();
    let (sender, receiver) = oneshot::channel();
    tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut received = Vec::new();
        stream.read_to_end(&mut received).await.unwrap();
        sender.send(received).unwrap();
    });
    let proxy = start_proxy(&target).await;

    let (mut client, _) = connect_async(format!("ws://{proxy}/{target}"))
        .await
        .unwrap();
    client
        .send(Message::binary(b"hello".to_vec()))
        .await
        .unwrap();
    client.close(None).await.unwrap();

    let received = tokio::time::timeout(TIMEOUT, receiver)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(received, b"hello");
}

#[tokio::test]
async fn echoes_the_requested_subprotocol() {
    let echo = start_echo().await;
    let proxy = start_proxy(&echo).await;
    let mut request = format!("ws://{proxy}/{echo}")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("sec-websocket-protocol", "binary".parse().unwrap());

    let (_, response) = connect_async(request).await.unwrap();

    assert_eq!(
        response.headers().get("sec-websocket-protocol").unwrap(),
        "binary"
    );
}
