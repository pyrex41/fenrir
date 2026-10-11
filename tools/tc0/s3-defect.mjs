// The S3 defective original, derived exactly from the reference candidate source:
// match selects the arm at the constructor's declared position instead of by name,
// with every trace of the mutant option removed. Refuses if the source moved.
const EDITS=[
 ['constructor(artifact,input,{reverseOperands=false,armByPosition=false,wrapOverflow=false}={}){','constructor(artifact,input,{reverseOperands=false,wrapOverflow=false}={}){'],
 ['this.armByPosition=armByPosition;',''],
 [' // Mutant support only (armByPosition): a constructor\'s position in its declaration.\n',' // A constructor\'s position in its declaration.\n'],
 ['const arm=this.armByPosition?f.arms[this.constructorIndex(c.value[1],c.value[2])]:f.arms.find(arm=>arm[0]===c.value[2]);','const arm=f.arms[this.constructorIndex(c.value[1],c.value[2])];']
];
export function makeDefective(source){
 let out=source;for(const [from,to] of EDITS){if(out.split(from).length!==2)throw new Error('Candidate changed shape; update the defect transform');out=out.replace(from,to);}
 if(/armByPosition|arm_by_position|[Mm]utant/.test(out))throw new Error('Defective source still names the injected defect');
 return out;
}
