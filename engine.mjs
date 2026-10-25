export const date=d=>{const t=d||new Date();return [t.getFullYear(),String(t.getMonth()+1).padStart(2,'0'),String(t.getDate()).padStart(2,'0')].join('-')};
export const plus=(s,n)=>{const d=new Date(s+'T12:00:00');d.setDate(d.getDate()+n);return date(d)};
export const mins=t=>Number(t.slice(0,2))*60+Number(t.slice(3,5));
export const week=(s,anchor)=>Math.floor((new Date(s+'T12:00:00')-new Date((anchor||'2026-09-07')+'T12:00:00'))/604800000)%2===0?'A':'B';
export function parseImport(text,order,year,programme){
 let rows=[],row=[],v='',q=false;
 for(let i=0;i<text.length;i++){const c=text[i];if(c==='"'){if(q&&text[i+1]==='"'){v+='"';i++}else q=!q}else if(!q&&(c===','||c==='\t')){row.push(v.trim());v=''}else if(!q&&(c==='\n'||c==='\r')){if(c==='\r'&&text[i+1]==='\n')i++;row.push(v.trim());if(row.some(Boolean))rows.push(row);row=[];v=''}else v+=c}
 if(q)throw Error('Close the quoted CSV field.');row.push(v.trim());if(row.some(Boolean))rows.push(row);
 const h=rows[0]?.map(x=>x.toLowerCase().replaceAll(' ',''));let headers=h?.includes('firstname')||h?.includes('forename');if(headers)rows.shift();
 const seen=new Set();return rows.map((r,i)=>{let first,last,email='';if(headers){first=r[h.findIndex(x=>['firstname','forename'].includes(x))];last=r[h.findIndex(x=>['lastname','surname'].includes(x))];email=r[h.indexOf('email')]||''}else if(r.length>1){[first,last]=order==='last-first'?[r[1],r[0]]:r;email=r[2]||''}else{const a=r[0].split(/\s+/);if(order==='last-first'){last=a.shift();first=a.join(' ')}else{first=a.shift();last=a.join(' ')}}if(!first||!last)throw Error('Row '+(i+1)+': include both names.');const k=(first+' '+last).toLowerCase();if(seen.has(k))throw Error('Duplicate name on row '+(i+1)+'. Add a middle name if these are different people.');seen.add(k);return {first,last,email,year:Number(year),programme_id:programme||null}})}
export const CAPS={
 admin:['records','structure','schedule','register','teach','support','results','settings'],
 registry:['records','structure','register','support','results'],
 programme_leader:['structure','schedule','register','teach','support','results'],
 lecturer:['register','teach','support'],
 timetable_manager:['schedule'],support:['support'],viewer:[],student:[]
};
export function generatePlan(state,{from,weeks=2,repeat=1,moduleIds=[]}){
 if(weeks<1||weeks>8||repeat<1||repeat>4)throw Error('Use 1–8 weeks and 1–4 sessions per module each week.');
 const all=state.items,modules=all.filter(i=>i.kind==='module'&&moduleIds.includes(i.id)),rooms=all.filter(i=>i.kind==='room'&&!i.data.archived),existing=all.filter(i=>i.kind==='session'&&!i.data.cancelled).map(i=>i.data),enrol=all.filter(i=>i.kind==='enrolment'),plan=[];
 if(!modules.length||!rooms.length)throw Error('Choose modules and add classrooms first.');
 const students=m=>new Set(enrol.filter(e=>e.data.module===m).map(e=>e.data.student));
 const clashes=(a,b)=>a.date===b.date&&mins(a.start)<mins(b.end)+10&&mins(a.end)+10>mins(b.start)&&(a.teacher===b.teacher||a.room===b.room||a.module===b.module||[...students(a.module)].some(s=>students(b.module).has(s)));
 for(let w=0;w<weeks;w++)for(let r=0;r<repeat;r++)for(const mod of modules){
  if(!mod.data.teacher)throw Error('Assign a lecturer to '+mod.data.title+' before generating.');
  let found;const suitable=rooms.filter(room=>Number(room.data.capacity)>=Number(mod.data.capacity));
  for(let day=0;day<7&&!found;day++){const d=plus(from,w*7+day);if([0,6].includes(new Date(d+'T12:00:00').getDay()))continue;
   for(const start of ['09:00','10:15','11:30','13:00','14:15','15:30'])for(const room of suitable){
    const end=String(Number(start.slice(0,2))+1).padStart(2,'0')+start.slice(2);
    const candidate={title:mod.data.title,module:mod.id,room:room.id,teacher:mod.data.teacher,date:d,start,end,type:'Lecture',cancelled:false};
    if(![...existing,...plan].some(b=>clashes(candidate,b))){found=candidate;break}
   }
  }if(!found)throw Error('No suitable slot for '+mod.data.title+'. Nothing has been published. Add rooms, reduce sessions or change the date.');
  plan.push(found);if(plan.length>200)throw Error('Generate no more than 200 sessions per batch.');
 }
 return plan;
}
export function moduleSummary(state,student,module){
 const assessments=state.items.filter(x=>x.kind==='assessment'&&x.data.module===module);
 const results=state.items.filter(x=>x.kind==='result'&&x.data.student===student&&x.data.released);
 const weight=assessments.reduce((n,a)=>n+Number(a.data.weight),0);
 let complete=weight===100,weighted=0;
 for(const a of assessments){const r=results.filter(r=>r.data.assessment===a.id).sort((a,b)=>Number(b.data.attempt)-Number(a.data.attempt))[0];if(!r)complete=false;else weighted+=Number(r.data.mark)*Number(a.data.weight)/100}
 return {complete,weighted:complete?weighted.toFixed(1):null,weight};
}

