import {date,plus} from './engine.mjs';
const uid=()=>crypto.randomUUID();
export function initial(ap){
 const staffId=uid(),otherStaff=uid(),studentId=uid(),room1=uid(),room2=uid(),prog=uid(),modules=[uid(),uid(),uid(),uid(),uid()];
 const state={role:'admin',userId:staffId,studentId:null,institution:ap==='college'?'Northbridge College':'Northbridge University',settings:{name:ap==='college'?'Northbridge College':'Northbridge University',years:ap==='college'?3:6,choicesOpen:true,allowCodes:ap==='college',status:'open',weekAStart:'2026-09-07'},settingsRevision:0,staff:[{id:staffId,name:'Jamie Lewis',email:'jamie@example.ac.uk',role:'admin'},{id:otherStaff,name:'Dr Morgan Ellis',email:'morgan@example.ac.uk',role:'lecturer'}],students:[{id:studentId,first:'Alex',last:'Morgan',year:1,email:'alex@example.ac.uk',programme_id:prog,notes:'Entry qualifications verified.',archived:false,revision:0,login_code:'A1'.repeat(16),access_code:'HE-1048-8291'},{id:uid(),first:'Priya',last:'Shah',year:1,email:'priya@example.ac.uk',programme_id:prog,notes:'',archived:false,revision:0,login_code:'B2'.repeat(16),access_code:'HE-1048-8292'},{id:uid(),first:'Oliver',last:'Bennett',year:1,email:'oliver@example.ac.uk',programme_id:prog,notes:'',archived:false,revision:0,login_code:'C3'.repeat(16),access_code:'HE-1048-8293'}],items:[],files:[],audit:[]};
 const add=(kind,data,id=uid())=>{state.items.push({id,kind,data,revision:0,created_at:new Date().toISOString()});return id};
 add('programme',{title:ap==='college'?'Creative Arts pathway':'BSc Computer Science',years:3,annualCredits:120},prog);
 add('room',{title:ap==='college'?'A01':'Lecture Theatre 1',building:'Main campus',capacity:60},room1);
 add('room',{title:ap==='college'?'A02':'Seminar Room 04',building:'Main campus',capacity:30},room2);
 const titles=ap==='college'?['Film Studies','Business','Art & Design','English Literature','Mathematics']:['Introduction to Computer Science','Research Methods','Database Systems','Programming Practice','Academic Skills'];
 titles.forEach((title,i)=>add('module',{title,subject:title,group:i<3?'option':'core',qualification:ap==='college'?'A level':'Degree module',programme:prog,year:1,teacher:staffId,capacity:24,credits:ap==='college'?0:20,compulsory:i===0,prerequisites:[]},modules[i]));
 for(const p of state.students)for(const module of modules)add('enrolment',{student:p.id,module});
 for(let i=0;i<3;i++)add('session',{title:titles[i],module:modules[i],room:i===1?room2:room1,teacher:staffId,date:date(),start:['09:00','11:00','14:00'][i],end:['10:00','12:00','15:00'][i],type:['Lecture','Seminar','Workshop'][i],cancelled:false});
 for(let i=1;i<=4;i++)add('session',{title:titles[i],module:modules[i],room:room1,teacher:staffId,date:plus(date(),i),start:'10:00',end:'11:00',type:'Lecture',cancelled:false});
 const assessment=add('assessment',{title:ap==='college'?'Documentary proposal':'Research proposal',module:modules[0],body:'Develop a clear research question, explain your approach and cite the sources that inform your proposal.',due:plus(date(),4)+'T16:00:00Z',weight:100,passMark:40,published:true});
 add('assessment',{title:ap==='college'?'Creative portfolio':'Programming portfolio',module:modules[1],body:'Submit your portfolio with a short reflection on your work.',due:plus(date(),8)+'T12:00:00Z',weight:100,passMark:40,published:true});
 add('submission',{title:'Research proposal submission',student:state.students[1].id,module:modules[0],assessment,body:'A fictional submission for demonstration.',submittedAt:new Date().toISOString(),status:'Submitted',late:false});
 add('request',{title:'Coursework extension',student:studentId,assessment,type:'Extension',body:'Please review my request for additional time.',status:'Pending'});
 add('appointment',{title:'Personal tutor meeting',student:studentId,staff:staffId,date:plus(date(),2),time:'10:30',status:'Booked',body:'Discuss the first semester and study plans.'});
 add('appointment',{title:'Project planning',student:state.students[1].id,staff:staffId,date:plus(date(),4),time:'14:00',status:'Booked'});
 add('project',{title:ap==='college'?'Independent film project':'Accessible campus navigation',student:studentId,staff:otherStaff,deadline:plus(date(),90),status:'Proposal',body:'Explore a practical project and agree your first milestones.',milestones:'Proposal review\nResearch plan\nFirst draft\nFinal submission'});
 add('notice',{title:'Semester planning',body:'Programme schedules are ready to review. Check your timetable before the start of teaching.',published:true});
 add('notice',{title:'Library resources',body:'New research collections and study spaces are now available.',published:true});
 add('resource',{title:'Getting started with your module',module:modules[0],body:'Read your module handbook, review the assessment brief and speak to your lecturer if you have questions.',published:true});
 return state;
}
function visible(s,mode){
 const v=structuredClone(s);if(mode==='student'){const p=v.students.find(p=>!p.archived);v.role='student';v.studentId=p.id;v.students=[p];delete p.login_code;delete p.notes;
 const modules=v.items.filter(i=>i.kind==='enrolment'&&i.data.student===p.id).map(i=>i.data.module);
 v.items=v.items.filter(i=>['module','programme','room'].includes(i.kind)||(['notice','resource','assessment'].includes(i.kind)&&i.data.published&&(!i.data.module||modules.includes(i.data.module)))||(i.kind==='session'&&modules.includes(i.data.module))||(i.data.student===p.id&&(i.kind!=='result'||i.data.released)));
 v.items.forEach(i=>delete i.data.privateNote);v.files=v.files.filter(f=>v.items.some(i=>i.id===f.item));v.audit=[];
 }return v;
}
export async function call(ap,mode,action,data){
 let s;try{s=JSON.parse(localStorage.getItem('he-demo-'+ap))}catch{}if(!s)s=initial(ap);
 const add=(kind,d)=>{const id=uid();s.items.push({id,kind,data:d,revision:0,created_at:new Date().toISOString()});return id};
 const student=s.students.find(p=>!p.archived);
 if(action==='file_get'){const f=s.files.find(f=>f.id===data.id);if(!f)throw Error('File unavailable.');return f}
 if(action==='import'||action==='student'){for(const p of action==='import'?data.students:[data]){if(p.id){Object.assign(s.students.find(x=>x.id===p.id),p,{revision:p.revision+1});if(p.archived)s.items=s.items.filter(i=>i.kind!=='enrolment'||i.data.student!==p.id)}else{if(p.year<1||p.year>s.settings.years)throw Error('Choose a valid study year.');const person={...p,id:uid(),notes:p.notes||'',revision:0,archived:false,login_code:uid().replaceAll('-','').toUpperCase(),access_code:'HE-'+uid().slice(0,12).toUpperCase()};s.students.push(person);for(const m of data.modules||[])add('enrolment',{student:person.id,module:m})}}}
 if(action==='choices'){const st=mode==='student'?student.id:data.student;if(ap==='college'&&data.modules.length&& (data.modules.length!==5||data.modules.filter(id=>s.items.find(i=>i.id===id)?.data.group==='core').length!==2))throw Error('Choose three options and two core subjects.');s.items=s.items.filter(i=>i.kind!=='enrolment'||i.data.student!==st);for(const m of data.modules)add('enrolment',{student:st,module:m})}
 if(action==='save'){let d={...data.data};if(mode==='student')d={...d,student:student.id,status:data.kind==='submission'?'Submitted':'Pending'};if(data.kind==='submission'){const a=s.items.find(i=>i.id===d.assessment);d.module=a.data.module;d.submittedAt=new Date().toISOString();d.late=new Date()>new Date(a.data.due)}if(data.kind==='result')d.module=s.items.find(i=>i.id===d.assessment)?.data.module;
 let id=data.id;if(id){const i=s.items.find(i=>i.id===id);i.data=d;i.revision++}else id=add(data.kind,d);s.savedId=id;
 if(data.file)s.files.push({id:uid(),item:id,...data.file});
 }
 if(action==='register'||action==='daily_register'){if(s.settings.status!=='open')throw Error('Attendance is locked while closed or closing.');const sess=action==='register'?s.items.find(i=>i.id===data.session):null;for(const m of data.marks){const session=sess?.id||data.date+'-'+data.slot,old=s.items.find(i=>i.kind==='attendance'&&i.data.session===session&&i.data.student===m.student);const d={...m,session,module:sess?.data.module,date:sess?.data.date||data.date};if(old){old.data=d;old.revision++}else add('attendance',d)}}
 if(action==='sessions')for(const d of data.sessions)add('session',d);
 if(action==='settings'){s.settings=data.settings;s.settingsRevision++}
 if(action==='role')s.staff.find(x=>x.id===data.user).role=data.role;
 if(action==='rotate'){const p=s.students.find(s=>s.id===data.id);p.login_code=uid().replaceAll('-','').toUpperCase();p.access_code='HE-'+uid().slice(0,12);p.revision++}
 if(action!=='read'){s.audit.unshift({action,at:new Date().toISOString()});s.message='Saved in this device’s fictional demo.'}
 localStorage.setItem('he-demo-'+ap,JSON.stringify(s));return visible(s,mode);
}

