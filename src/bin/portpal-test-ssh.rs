use std::env;
use std::net::TcpListener;
use std::thread;
use std::time::Duration;

fn main() {
    match env::var("PORTPAL_TEST_SSH_MODE").as_deref() {
        Ok("exit-immediately") => return,
        Ok("listen") => run_listener().unwrap(),
        _ => hold_open(),
    }
}

fn run_listener() -> std::io::Result<()> {
    let local_port = forwarded_local_port().expect("missing -L forwarded port argument");
    let listener = TcpListener::bind(("127.0.0.1", local_port))?;
    listener.set_nonblocking(true)?;

    loop {
        match listener.accept() {
            Ok((_stream, _address)) => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    }
}

fn hold_open() -> ! {
    loop {
        thread::sleep(Duration::from_millis(100));
    }
}

fn forwarded_local_port() -> Option<u16> {
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "-L" {
            return args.next().and_then(|value| {
                value
                    .split(':')
                    .next()
                    .and_then(|port| port.parse::<u16>().ok())
            });
        }
    }
    None
}
