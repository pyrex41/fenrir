// Unified diff with the exact output of Python's difflib.unified_diff (three
// context lines, no dates), including its SequenceMatcher "popular line"
// heuristic. The retained patch text and its digest are part of the overlay
// build evidence, so the bytes must not depend on which host produced them.

// str.splitlines(keepends=True): Python's line boundaries.
export function keepLines(text) {
  const out=[];let at=0;
  for(const m of text.matchAll(/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/g)) {
    out.push(text.slice(at,m.index+m[0].length));
    at=m.index+m[0].length;
  }
  if(at<text.length)out.push(text.slice(at));
  return out;
}

function matchingBlocks(a,b) {
  const b2j=new Map();
  b.forEach((line,j)=>{if(!b2j.has(line))b2j.set(line,[]);b2j.get(line).push(j);});
  // Lines occurring in more than 1% of a long sequence are not used as anchors.
  if(b.length>=200) {
    const limit=Math.floor(b.length/100)+1;
    for(const [line,indices] of [...b2j])if(indices.length>limit)b2j.delete(line);
  }
  const longest=(alo,ahi,blo,bhi)=>{
    let besti=alo,bestj=blo,bestsize=0,j2len=new Map();
    for(let i=alo;i<ahi;i++) {
      const next=new Map();
      for(const j of b2j.get(a[i])||[]) {
        if(j<blo)continue;
        if(j>=bhi)break;
        const k=(j2len.get(j-1)||0)+1;
        next.set(j,k);
        if(k>bestsize){besti=i-k+1;bestj=j-k+1;bestsize=k;}
      }
      j2len=next;
    }
    while(besti>alo&&bestj>blo&&a[besti-1]===b[bestj-1]){besti--;bestj--;bestsize++;}
    while(besti+bestsize<ahi&&bestj+bestsize<bhi&&a[besti+bestsize]===b[bestj+bestsize])bestsize++;
    return [besti,bestj,bestsize];
  };
  const queue=[[0,a.length,0,b.length]],found=[];
  while(queue.length) {
    const [alo,ahi,blo,bhi]=queue.pop();
    const [i,j,k]=longest(alo,ahi,blo,bhi);
    if(!k)continue;
    found.push([i,j,k]);
    if(alo<i&&blo<j)queue.push([alo,i,blo,j]);
    if(i+k<ahi&&j+k<bhi)queue.push([i+k,ahi,j+k,bhi]);
  }
  found.sort((x,y)=>x[0]-y[0]||x[1]-y[1]||x[2]-y[2]);
  const blocks=[];let i1=0,j1=0,k1=0;
  for(const [i2,j2,k2] of found) {
    if(i1+k1===i2&&j1+k1===j2)k1+=k2;
    else {if(k1)blocks.push([i1,j1,k1]);i1=i2;j1=j2;k1=k2;}
  }
  if(k1)blocks.push([i1,j1,k1]);
  blocks.push([a.length,b.length,0]);
  return blocks;
}

function opcodes(a,b) {
  const out=[];let i=0,j=0;
  for(const [ai,bj,size] of matchingBlocks(a,b)) {
    const tag=i<ai&&j<bj?'replace':i<ai?'delete':j<bj?'insert':'';
    if(tag)out.push([tag,i,ai,j,bj]);
    i=ai+size;j=bj+size;
    if(size)out.push(['equal',ai,i,bj,j]);
  }
  return out;
}

function grouped(a,b,n) {
  let codes=opcodes(a,b);
  if(!codes.length)codes=[['equal',0,1,0,1]];
  if(codes[0][0]==='equal'){const [tag,i1,i2,j1,j2]=codes[0];codes[0]=[tag,Math.max(i1,i2-n),i2,Math.max(j1,j2-n),j2];}
  if(codes.at(-1)[0]==='equal'){const [tag,i1,i2,j1,j2]=codes.at(-1);codes[codes.length-1]=[tag,i1,Math.min(i2,i1+n),j1,Math.min(j2,j1+n)];}
  const groups=[];let group=[];
  for(let [tag,i1,i2,j1,j2] of codes) {
    if(tag==='equal'&&i2-i1>n+n) {
      group.push([tag,i1,Math.min(i2,i1+n),j1,Math.min(j2,j1+n)]);
      groups.push(group);group=[];
      i1=Math.max(i1,i2-n);j1=Math.max(j1,j2-n);
    }
    group.push([tag,i1,i2,j1,j2]);
  }
  if(group.length&&!(group.length===1&&group[0][0]==='equal'))groups.push(group);
  return groups;
}

const range=(start,stop)=>{
  let beginning=start+1;const length=stop-start;
  if(length===1)return String(beginning);
  if(!length)beginning--;
  return `${beginning},${length}`;
};

export function unifiedDiff(original,changed,fromfile,tofile) {
  const a=keepLines(original),b=keepLines(changed);
  let out='',started=false;
  for(const group of grouped(a,b,3)) {
    if(!started){started=true;out+=`--- ${fromfile}\n+++ ${tofile}\n`;}
    const first=group[0],last=group.at(-1);
    out+=`@@ -${range(first[1],last[2])} +${range(first[3],last[4])} @@\n`;
    for(const [tag,i1,i2,j1,j2] of group) {
      if(tag==='equal'){for(const line of a.slice(i1,i2))out+=' '+line;continue;}
      if(tag==='replace'||tag==='delete')for(const line of a.slice(i1,i2))out+='-'+line;
      if(tag==='replace'||tag==='insert')for(const line of b.slice(j1,j2))out+='+'+line;
    }
  }
  return out;
}
