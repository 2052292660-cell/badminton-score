export const teams = [
 ['朱雨乐','肖云凯'], ['宋远见','王永盛'], ['察志祥','李俊豪'], ['孔子涵','郑昌盛'],
 ['吴鹏旭','李雨航'], ['张俊涵','杨锦南'], ['廖浩轩','牟彬洁'], ['李凯南','廉培宇'],
 ['江玉涛','李铮昂'], ['张江杭','刘仕杰'], ['安羿驰','毕强'], ['寇北辰','许欣悦'], ['刘家润','谢镇谦']
].map((players,i)=>({id:i+1,players}));
export type Match = {id:number;a:number;b:number};
export const matches:Match[] = [];
for(let a=1;a<=13;a++)for(let b=a+1;b<=13;b++)matches.push({id:matches.length+1,a,b});
export type Game = [number,number];
export type Result = {id:string;matchId:number;revision:number;games:Game[];reporter:string;note:string;playedAt:string;court:string;reason:string;createdAt:string};
export function gameError(a:number,b:number) {
 if(!Number.isInteger(a)||!Number.isInteger(b)||a<0||b<0||a>15||b>15)return '每局分数须为 0–15 的整数';
 const hi=Math.max(a,b),lo=Math.min(a,b);
 if(hi===11&&lo<=9 || hi>=12&&hi<=14&&hi-lo===2 || hi===15&&(lo===13||lo===14))return '';
 return '每局 11 分；10 平后须领先 2 分，15 分封顶（15:14 有效）';
}
export function validateGames(games:Game[]) {
 if(!Array.isArray(games)||games.length<2||games.length>3)return '请填写完整的 2 局或 3 局比分';
 let aw=0,bw=0;
 for(let i=0;i<games.length;i++) {
  if(aw===2||bw===2)return '已连赢两局，无需填写第三局';
  if(!Array.isArray(games[i])||games[i].length!==2)return '请填写双方的完整比分';
  const error=gameError(games[i][0],games[i][1]); if(error)return `第 ${i+1} 局：${error}`;
  if(games[i][0]>games[i][1])aw++;else bw++;
 }
 return aw===2||bw===2?'':'三局两胜：目前尚未产生获胜方';
}
export function wins(games:Game[]){return [games.filter(g=>g[0]>g[1]).length,games.filter(g=>g[0]<g[1]).length];}
export function standings(results:Result[]) {
 const rows=teams.map(t=>({...t,played:0,won:0,lost:0,gf:0,ga:0,pf:0,pa:0}));
 for(const r of results) {const m=matches.find(m=>m.id===r.matchId);if(!m)continue;const a=rows[m.a-1],b=rows[m.b-1],w=wins(r.games);a.played++;b.played++;a.gf+=w[0];a.ga+=w[1];b.gf+=w[1];b.ga+=w[0];if(w[0]>w[1]){a.won++;b.lost++;}else{b.won++;a.lost++;}for(const [x,y] of r.games){a.pf+=x;a.pa+=y;b.pf+=y;b.pa+=x;}}
 return rows.sort((a,b)=>b.won-a.won||(b.gf-b.ga)-(a.gf-a.ga)||(b.pf-b.pa)-(a.pf-a.pa)||a.id-b.id);
}
