mod cli;
mod config;
mod daemon;
mod health;
mod ipc;
mod paths;
mod ssh;
mod state;

use anyhow::Result;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    cli::run()
}
