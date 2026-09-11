use std::io::{self, IsTerminal};
use std::sync::Arc;

use clap::Parser;
use tokio::net::TcpListener;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;
use wsproxy::{AllowList, serve};

/// WebSocket to TCP proxy for roBrowserLegacy.
#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Port to listen on
    #[arg(short, long, env = "PORT", default_value_t = 5999)]
    port: u16,

    /// Comma separated list of host:port targets the proxy may connect to
    #[arg(short, long, value_name = "HOST:PORT,...")]
    allow: Option<String>,
}

#[tokio::main]
async fn main() -> io::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with_ansi(io::stdout().is_terminal())
        .init();

    let cli = Cli::parse();
    let allow = AllowList::new(cli.allow.as_deref().unwrap_or_default());
    if allow.is_empty() {
        warn!("no --allow list given: the proxy relays to any requested host:port");
    }

    let listener = TcpListener::bind(("0.0.0.0", cli.port)).await?;
    info!(port = cli.port, "wsproxy listening");
    serve(listener, Arc::new(allow)).await;
    Ok(())
}
