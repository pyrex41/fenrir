#[allow(dead_code)]
mod service {
    include!("reference.rs");
    pub fn run() {
        include!("cases.rs");
    }
}
fn main() { service::run(); }
