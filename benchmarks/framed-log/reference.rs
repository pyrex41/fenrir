use std::io::{self, Read, Write};

#[derive(Clone, Copy, Default)]
struct Aggregate {
    records: u64,
    bytes: u64,
    sum: u64,
}

enum State {
    Length,
    Low(u8),
    Key(usize),
    Payload(usize, usize),
}

fn process(mut input: impl Read, chunk: usize) -> io::Result<Result<[Aggregate; 64], u64>> {
    let mut buffer = vec![0; chunk];
    let mut groups = [Aggregate::default(); 64];
    let mut offset = 0;
    let mut state = State::Length;
    loop {
        let n = match input.read(&mut buffer) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if n == 0 {
            return Ok(if matches!(state, State::Length) {
                Ok(groups)
            } else {
                Err(offset)
            });
        }
        let mut i = 0;
        while i < n {
            let byte = buffer[i];
            let mut consumed = 1;
            state = match state {
                State::Length => State::Low(byte),
                State::Low(high) => {
                    let len = u16::from_be_bytes([high, byte]) as usize;
                    if len == 0 {
                        return Ok(Err(offset - 1));
                    }
                    State::Key(len)
                }
                State::Key(len) => {
                    let key = byte as usize;
                    if key >= groups.len() {
                        return Ok(Err(offset));
                    }
                    groups[key].records += 1;
                    if len == 1 {
                        State::Length
                    } else {
                        State::Payload(key, len - 1)
                    }
                }
                State::Payload(key, remaining) => {
                    consumed = remaining.min(n - i);
                    groups[key].sum += buffer[i..i + consumed]
                        .iter()
                        .map(|&b| u64::from(b))
                        .sum::<u64>();
                    groups[key].bytes += consumed as u64;
                    if consumed == remaining {
                        State::Length
                    } else {
                        State::Payload(key, remaining - consumed)
                    }
                }
            };
            i += consumed;
            offset += consumed as u64;
        }
    }
}

fn main() -> io::Result<()> {
    let mut args = std::env::args().skip(1);
    let chunk = args
        .next()
        .unwrap_or_else(|| "8192".into())
        .parse::<usize>()
        .ok();
    let Some(size @ 1..=65536) = chunk else {
        std::process::exit(2)
    };
    if args.next().is_some() {
        std::process::exit(2);
    }
    match process(io::stdin().lock(), size)? {
        Err(offset) => {
            eprintln!("reject {offset}");
            std::process::exit(1);
        }
        Ok(groups) => {
            let mut out = io::stdout().lock();
            for (key, group) in groups.iter().enumerate().filter(|(_, g)| g.records > 0) {
                writeln!(
                    out,
                    "{} {} {} {}",
                    key, group.records, group.bytes, group.sum
                )?;
            }
        }
    }
    Ok(())
}
