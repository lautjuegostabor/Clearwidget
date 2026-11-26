//! One-shot test using the owner's existing BariStore session and cached IPA.
use crate::{apple::{gsa,portal},device::{services,session::Session},install,pairing::flow,state};
use std::{io::{self,Write},path::Path};
const HOST:&str="Payload/ClearWidget.app";
const EXT:&str="Payload/ClearWidget.app/PlugIns/ClearWidgetExtension.appex";
pub async fn run()->Result<(),String>{
    let entries:Vec<_>=install::installed().into_iter().filter(|e|e.original_id=="com.clearwidget.app").collect();
    if entries.len()!=1{return Err("Se requiere exactamente una instalación registrada de ClearWidget.".into());}
    let mut entry=entries.into_iter().next().unwrap();
    let team=entry.team.clone();
    let host=entry.bundle_id.clone();
    if team.len()!=10 || !team.bytes().all(|b|b.is_ascii_uppercase()||b.is_ascii_digit()) ||
        !(host=="com.clearwidget.app" || host==format!("com.clearwidget.app.{team}")) ||
        entry.ids.len()!=2 || entry.ids.get(HOST)!=Some(&host) ||
        entry.ids.get(EXT)!=Some(&format!("{host}.widget")) || entry.cert_serial.is_empty(){
        return Err("Identidad registrada no compatible; no se modificó la instalación.".into());
    }
    let saved_team=std::fs::read_to_string(state::path("team")).map_err(|_|"No hay equipo guardado")?;
    if saved_team.lines().next().map(str::trim)!=Some(team.as_str()){return Err("Equipo distinto; no se modificó nada.".into());}
    if !state::path("signing-key.der").is_file(){return Err("Falta la clave existente.".into());}
    let cache=std::fs::canonicalize(state::path("ipas")).map_err(|_|"No hay caché IPA")?;
    let path=std::fs::canonicalize(Path::new(&entry.ipa_path)).map_err(|_|"IPA original no encontrado en caché")?;
    if !path.starts_with(&cache)||!path.is_file()||std::fs::metadata(&path).map_err(|_|"No se pudo inspeccionar el IPA")?.len()>16*1024*1024{
        return Err("IPA local no compatible.".into());
    }
    let bytes=std::fs::read(&path).map_err(|_|"No se pudo leer el IPA")?;
    let opts=entry.signing_options();
    if opts.remove_extensions||opts.increased_memory||!opts.icon.is_empty(){return Err("Opciones de instalación no compatibles.".into());}
    println!("Prueba de Atajos: reinstala únicamente ClearWidget 0.5.8 build 14 sobre sus mismos identificadores, usando el certificado existente. No solicita contraseña ni revoca certificados.");
    print!("Escribí PROBAR para autorizar: ");io::stdout().flush().map_err(|_|"Terminal")?;
    let mut answer=String::new();io::stdin().read_line(&mut answer).map_err(|_|"Terminal")?;
    if answer.trim()!="PROBAR"{return Err("Cancelado.".into());}
    let record=flow::load_record().ok_or("No hay emparejamiento existente")?;
    let session=Session::open(&record).await.map_err(|_|"Emparejamiento o LocalDevVPN no disponible")?;
    if session.udid!=record.peer.udid||session.udid.is_empty(){return Err("El dispositivo no coincide.".into());}
    let installed=services::installed_apps(&session).await.map_err(|_|"No se pudieron consultar las apps")?;
    if !installed.iter().any(|a|a.get("CFBundleIdentifier").and_then(plist::Value::as_string)==Some(host.as_str()) &&
        a.get("CFBundleVersion").and_then(plist::Value::as_string)==Some("14")){
        return Err("El build 14 registrado no está instalado.".into());
    }
    let (gs,account)=gsa::resume().await.map_err(|_|"Apple no aceptó la sesión existente; no se reintentó")?;
    let portal=portal::Portal{gs:&gs,account:&account};
    let selected=portal.teams().await.map_err(|_|"No se pudieron validar los equipos")?.into_iter().find(|t|t.id==team).ok_or("Equipo no autorizado")?;
    let ask:Box<install::Asker>=Box::new(|_,_,_|Box::pin(async{None}));
    let ctx=install::Context{gs:&gs,account:&account,team:&selected,udid:&session.udid,device_name:"iPhone",session:&session,ask:ask.as_ref(),
        reuse:install::Reuse::default(),previous:Some((&host,&entry.ids))};
    let prepared=install::prepare_and_sign(&ctx,bytes,&opts,&|s|println!("{s}")).await?;
    if prepared.main_id!=host||prepared.ids!=entry.ids||prepared.cert_serial!=entry.cert_serial||prepared.version!="0.5.8"{
        return Err("Cambió la identidad, certificado o versión. No se instaló.".into());
    }
    println!("Firma XML/DER y perfiles de ambos ejecutables verificados antes de instalar.");
    entry.expires=prepared.expires;
    install::install_signed(&session,&prepared.ipa,entry,&|stage,pct|println!("{stage}: {pct}%")).await?;
    println!("Instalación aceptada. Abrí Atajos y ejecutá Diagnóstico ClearWidget. La prueba solo termina cuando el widget confirma el puente.");
    Ok(())
}
