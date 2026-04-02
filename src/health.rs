use std::io;
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

pub fn is_process_alive(child: &mut std::process::Child) -> io::Result<bool> {
    match child.try_wait()? {
        None => Ok(true),
        Some(_) => Ok(false),
    }
}

pub fn can_reach_local_port(port: u16) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&address, Duration::from_millis(300)).is_ok()
}
