const envId=import.meta.env.VITE_CLOUDBASE_ENV_ID as string|undefined;
const publicKey=import.meta.env.VITE_CLOUDBASE_PUBLISHABLE_KEY as string|undefined;
export async function scoreFetch(path:string,init:RequestInit={}):Promise<Response>{
 if(!envId||!publicKey)throw new Error('记分数据库尚未连接，请联系组织者');
 const matchId=new URL(path,'https://score.local').searchParams.get('match');
 const name=init.method==='POST'?'badminton_submit':matchId?'badminton_history':'badminton_list';
 const args=init.method==='POST'?{p:JSON.parse(String(init.body))}:matchId?{p_match_id:Number(matchId)}:{};
 const res=await fetch(`https://${envId}.api.tcloudbasegateway.com/v1/rdb/rest/rpc/${name}`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${publicKey}`},body:JSON.stringify(args),signal:init.signal});
 let data;try{data=await res.json() as {status?:number;error?:string;message?:string};}catch{throw new Error('记分服务暂时不可用，请稍后重试');}
 if(!res.ok)throw new Error(data.message||data.error||'连接云端记分服务失败');
 return Response.json(data,{status:data.status??200});
}
