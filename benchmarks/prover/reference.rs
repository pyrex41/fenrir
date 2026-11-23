use std::{collections::VecDeque, env, fs};

#[derive(Clone)]
enum Term {
    Atom(u32),
    Not(Box<Term>),
    Binary(char, Box<Term>, Box<Term>),
}

fn parse<'a>(tokens: &mut impl Iterator<Item = &'a str>) -> Term {
    match tokens.next().expect("missing term") {
        "!" => Term::Not(Box::new(parse(tokens))),
        op @ ("&" | "|" | ">") => Term::Binary(
            op.chars().next().unwrap(),
            Box::new(parse(tokens)),
            Box::new(parse(tokens)),
        ),
        atom if atom.len() == 1 && atom.as_bytes()[0].is_ascii_lowercase() => {
            Term::Atom(1 << (atom.as_bytes()[0] - b'a'))
        }
        _ => panic!("invalid term"),
    }
}

enum Failure {
    Model(u32),
    Exhausted,
}

fn search<'a>(
    mut queue: VecDeque<(bool, &'a Term)>,
    mut pos: u32,
    mut neg: u32,
    fuel: &mut usize,
    proof: &mut String,
) -> Result<(), Failure> {
    if *fuel == 0 {
        return Err(Failure::Exhausted);
    }
    *fuel -= 1;
    let Some((sign, term)) = queue.pop_front() else {
        return Err(Failure::Model(pos));
    };
    match term {
        Term::Atom(bit) => {
            if bit & (if sign { neg } else { pos }) != 0 {
                proof.push('x');
                return Ok(());
            }
            if sign {
                pos |= bit;
            } else {
                neg |= bit;
            }
        }
        Term::Not(child) => queue.push_back((!sign, child)),
        Term::Binary(op, left, right) => {
            let first = (if *op == '>' { !sign } else { sign }, left.as_ref());
            if (*op == '&') != sign {
                proof.push('b');
                let mut branch = queue.clone();
                branch.push_back(first);
                search(branch, pos, neg, fuel, proof)?;
                queue.push_back((sign, right));
                return search(queue, pos, neg, fuel, proof);
            }
            queue.push_back(first);
            queue.push_back((sign, right));
        }
    }
    proof.push('s');
    search(queue, pos, neg, fuel, proof)
}

fn verify_branch<'a>(
    mut queue: VecDeque<(bool, &'a Term)>,
    mut pos: u32,
    mut neg: u32,
    tape: &mut std::slice::Iter<'_, u8>,
) -> bool {
    while let Some((sign, term)) = queue.pop_front() {
        let rule = tape.next().copied();
        match term {
            Term::Atom(bit) => {
                if bit & (if sign { neg } else { pos }) != 0 {
                    return rule == Some(b'x');
                }
                if sign {
                    pos |= bit
                } else {
                    neg |= bit
                }
            }
            Term::Not(child) => queue.push_back((!sign, child)),
            Term::Binary(op, left, right) => {
                let first = (if *op == '>' { !sign } else { sign }, left.as_ref());
                if (*op == '&') != sign {
                    if rule != Some(b'b') {
                        return false;
                    }
                    let mut branch = queue.clone();
                    branch.push_back(first);
                    if !verify_branch(branch, pos, neg, tape) {
                        return false;
                    }
                    queue.push_back((sign, right));
                    continue;
                }
                queue.push_back(first);
                queue.push_back((sign, right));
            }
        }
        if rule != Some(b's') {
            return false;
        }
    }
    false
}

fn verify_proof(goal: &Term, proof: &[u8]) -> bool {
    let mut tape = proof.iter();
    verify_branch(VecDeque::from([(false, goal)]), 0, 0, &mut tape) && tape.len() == 0
}

fn main() {
    let corpus = fs::read_to_string(env::args().nth(1).expect("corpus path")).unwrap();
    for line in corpus.lines() {
        let mut tokens = line.split_whitespace();
        let name = tokens.next().unwrap();
        let expected = tokens.next().unwrap();
        let budget: usize = tokens.next().unwrap().parse().unwrap();
        let goal = parse(&mut tokens);
        assert!(tokens.next().is_none());
        let mut fuel = budget;
        let mut proof = String::new();
        let result = search(
            VecDeque::from([(false, &goal)]),
            0,
            0,
            &mut fuel,
            &mut proof,
        );
        let (status, witness) = match result {
            Ok(()) => {
                let tape = proof.as_bytes();
                assert!(verify_proof(&goal, tape));
                assert!(!verify_proof(&goal, &tape[..tape.len() - 1]));
                assert!(!verify_proof(&goal, &[tape, b"x"].concat()));
                assert!(!verify_proof(
                    &goal,
                    &[&tape[..tape.len() - 1], b"?"].concat()
                ));
                ("proof", proof)
            }
            Err(Failure::Model(mask)) => ("model", mask.to_string()),
            Err(Failure::Exhausted) => ("exhausted", "-".to_owned()),
        };
        assert_eq!(status, expected, "{name}");
        println!("{name} {status} {} {witness}", budget - fuel);
    }
}
