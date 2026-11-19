//! The fixture app of the linux-packages test: prints its version, and reads
//! the file beside its binary to show that the bundle was installed whole.

use std::path::PathBuf;

fn main() {
    let arg = std::env::args().nth(1);
    if arg.as_deref() != Some("--version") {
        eprintln!("usage: trebuchet-fixture --version");
        std::process::exit(2);
    }
    println!("trebuchet-fixture {}", env!("CARGO_PKG_VERSION"));

    // The data file sits beside the real binary, also when the command on
    // the PATH is a link to it.
    let data = std::env::current_exe()
        .and_then(|exe| exe.canonicalize())
        .map(|exe| exe.with_file_name("data").join("greeting.txt"))
        .unwrap_or_else(|_| PathBuf::from("data/greeting.txt"));
    match std::fs::read_to_string(&data) {
        Ok(text) => print!("{text}"),
        Err(error) => {
            eprintln!("{}: {error}", data.display());
            std::process::exit(1);
        }
    }
}
