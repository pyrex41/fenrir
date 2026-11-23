// A persistent packet-2 OTP port. Construct transactions and decide the v1
// application response here; the supervising adapter owns the SQLite call.
use std::io::{self, Read, Write};

fn int(n: i64) -> String {
    format!(r#"["int","{n}"]"#)
}

fn data(ty: &str, ctor: &str, fields: &[String]) -> String {
    let mut value = format!(r#"["data","{ty}","{ctor}""#);
    for field in fields {
        value.push(',');
        value.push_str(field);
    }
    value.push(']');
    value
}

fn transaction(t: u8, k: i64, d: u8, delivery: bool) -> String {
    let key = int(k);
    let digest = int(d.into());
    let (guard, writes) = if delivery {
        (
            "Pending",
            vec![data(
                "Write",
                "Finish",
                &[key.clone(), format!(r#"["bool",{}]"#, d == 1)],
            )],
        )
    } else {
        (
            "Once",
            vec![
                data("Write", "StageJob", &[]),
                data(
                    "Write",
                    "PutReport",
                    &[digest.clone(), format!(r#"["bytes","{d:02x}"]"#)],
                ),
                data("Write", "RecordKey", &[key.clone(), digest]),
            ],
        )
    };
    let ops = writes
        .into_iter()
        .rev()
        .fold(data("Writes", "Done", &[]), |rest, op| {
            data("Writes", "Then", &[op, rest])
        });
    data(
        "Tx",
        "Tx",
        &[
            data("Cap", "Tenant", &[int(t.into())]),
            data("Guard", guard, &[key]),
            ops,
        ],
    )
}

fn handle(packet: &[u8]) -> Option<String> {
    let reply = packet.first() == Some(&2);
    let cmd = if reply { &packet[1..] } else { packet };
    let (&opcode, rest) = cmd.split_first()?;
    let (&tenant, rest) = rest.split_first()?;
    let (key, rest) = match opcode {
        0 | 1 if *rest.first()? < 2 => (i64::from(rest[0]), &rest[1..]),
        3 | 4 => (
            i64::from_be_bytes(rest.get(..8)?.try_into().ok()?),
            &rest[8..],
        ),
        _ => return None,
    };
    let (&digest, body) = rest.split_first()?;
    if tenant > 1 || key < 0 || digest > 1 {
        return None;
    }
    let delivery = matches!(opcode, 1 | 4);
    match (reply, body) {
        (false, []) => Some(transaction(tenant, key, digest, delivery)),
        (true, [kind, recorded, receipt @ ..])
            if !delivery && receipt.len() == 40 && *kind <= 1 =>
        {
            if *kind == 1 && digest != *recorded {
                return Some(data(
                    "Response",
                    "Conflict",
                    &[int(tenant.into()), int(key)],
                ));
            }
            let fields: Vec<_> = receipt
                .chunks_exact(8)
                .map(|n| int(i64::from_be_bytes(n.try_into().unwrap())))
                .collect();
            Some(data(
                "Response",
                "Accepted",
                &[data("Receipt", "Receipt", &fields)],
            ))
        }
        (true, [2 | 3]) if delivery => Some(data("Response", "Delivered", &[])),
        (true, [2 | 3]) => Some(data("Response", "Refused", &[])),
        _ => None,
    }
}

fn main() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut header = [0u8; 2];
    loop {
        if input.read(&mut header[..1])? == 0 {
            return Ok(());
        }
        input.read_exact(&mut header[1..])?;
        let len = usize::from(u16::from_be_bytes(header));
        let mut buf = [0u8; 64];
        if len > buf.len() {
            return Err(io::Error::other("oversized request"));
        }
        input.read_exact(&mut buf[..len])?;
        let value = handle(&buf[..len]).ok_or_else(|| io::Error::other("invalid request"))?;
        output.write_all(&(value.len() as u16).to_be_bytes())?;
        output.write_all(value.as_bytes())?;
        output.flush()?;
    }
}
