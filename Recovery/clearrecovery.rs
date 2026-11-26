//! External profile-only recovery for the owner's ClearWidget installation.
//! Intended for Open Minis Linux guest. Never accepts secrets as command-line arguments.
use aes_gcm::{Aes256Gcm,KeyInit,aead::{Aead,Payload},Nonce};
#[cfg(feature="clear-bootstrap")] use rsa::pkcs8::EncodePrivateKey;
use base64::{engine::general_purpose::STANDARD,Engine};
use serde::{Deserialize,Serialize};
use std::{collections::BTreeMap,fs,io::{self,BufRead,Write},path::{Path,PathBuf},os::unix::fs::{OpenOptionsExt,DirBuilderExt,PermissionsExt}};
const HEADER:&[u8]=b"CLEARRECOVERY1";
#[derive(Serialize,Deserialize)]
struct Capsule{version:u8,request:String,files:BTreeMap<String,String>}
#[derive(Deserialize)] struct Request { bundles:Vec<Bundle>, #[serde(rename="previousExpiry")] previous_expiry:u64 }
#[derive(Deserialize)] struct Bundle { #[serde(rename="bundleID")] bundle_id:String,profile:String }
fn allowed(s:&str)->bool {
    matches!(s,"account.plist"|"pairing.plist"|"anisette-server"|"host-uuid"|"device-port") ||
        (s.starts_with("anisette-") && s.ends_with(".plist") && s.len()<200 && !s.contains('/') && !s.contains('\\') && !s.contains(".."))
}
fn validate(c:&Capsule)->Result<Vec<u8>,String>{
    if c.version!=1 || c.files.len()>40{return Err("Unsupported capsule".into());}
    for name in ["account.plist","pairing.plist","anisette-server"]{if !c.files.contains_key(name){return Err("Incomplete capsule".into());}}
    if !c.files.keys().any(|s|s.starts_with("anisette-") && s.ends_with(".plist")){return Err("Missing anisette identity".into());}
    let bytes=STANDARD.decode(&c.request).map_err(|_|"Invalid request")?;
    if bytes.len()>3_000_000{return Err("Request too large".into());}
    let r:Request=serde_json::from_slice(&bytes).map_err(|_|"Invalid profile request")?;
    if r.bundles.len()!=2 || r.previous_expiry==0{return Err("Expected app and extension profiles".into());}
    // Original identifiers plus the normal suffix produced by a development signer.
    let main=&r.bundles[0].bundle_id;
    let main_valid=main=="com.clearwidget.app" || main.strip_prefix("com.clearwidget.app.")
        .map(|s|!s.is_empty() && s.bytes().all(|b|b.is_ascii_alphanumeric())).unwrap_or(false);
    // BariStore appends the team suffix to the host, THEN the original extension suffix.
    if !main_valid || r.bundles[1].bundle_id!=format!("{main}.widget") || r.bundles.iter().any(|b|b.profile.len()>1_400_000){return Err("Unexpected effective bundle identifiers; no profiles changed".into());}
    Ok(bytes)
}
struct Staging(PathBuf);
impl Drop for Staging{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
fn stage(c:&Capsule)->Result<Staging,String>{
    let home=std::env::var_os("HOME").map(PathBuf::from).ok_or("No local home")?;
    let root=home.join(".clearrecovery");
    if !root.exists(){fs::DirBuilder::new().mode(0o700).create(&root).map_err(|_|"Cannot create private directory")?;}
    let m=fs::symlink_metadata(&root).map_err(|_|"Cannot check private directory")?;
    if !m.is_dir() || m.file_type().is_symlink() || m.permissions().mode()&0o077!=0{return Err("Unsafe local directory".into());}
    let path=root.join(format!("temporary-{}",uuid::Uuid::new_v4()));
    fs::DirBuilder::new().mode(0o700).create(&path).map_err(|_|"Cannot create private staging")?;
    let st=Staging(path);let mut total=0;
    for (name,value) in &c.files {
        if !allowed(name){return Err("Unexpected session file".into());}
        let data=STANDARD.decode(value).map_err(|_|"Invalid session file")?;total+=data.len();
        if total>1_000_000 || data.len()>256_000{return Err("Session too large".into());}
        let mut f=fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(st.0.join(name)).map_err(|_|"Cannot stage session")?;
        f.write_all(&data).map_err(|_|"Cannot write session")?;
    }
    Ok(st)
}
struct EchoGuard{fd:i32,previous:libc::termios}
impl Drop for EchoGuard{fn drop(&mut self){unsafe{libc::tcsetattr(self.fd,libc::TCSANOW,&self.previous);}}}
fn read_key()->Result<Vec<u8>,String>{
    // Refuse noninteractive input to avoid passing session material through logs/pipes.
    let fd=libc::STDIN_FILENO;
    if unsafe{libc::isatty(fd)}!=1{return Err("An interactive terminal is required".into());}
    let mut prev=std::mem::MaybeUninit::<libc::termios>::uninit();
    if unsafe{libc::tcgetattr(fd,prev.as_mut_ptr())}!=0{return Err("Cannot protect key input".into());}
    let prev=unsafe{prev.assume_init()};let mut next=prev;next.c_lflag&=!libc::ECHO;
    if unsafe{libc::tcsetattr(fd,libc::TCSANOW,&next)}!=0{return Err("Cannot disable key echo".into());}
    let guard=EchoGuard{fd,previous:prev};
    eprint!("Clave local del respaldo (no se muestra): ");io::stderr().flush().map_err(|_|"Terminal error")?;
    let mut line=String::new();io::stdin().lock().read_line(&mut line).map_err(|_|"Cannot read key")?;
    drop(guard);eprintln!();let key=STANDARD.decode(line.trim()).map_err(|_|"Invalid key")?;
    if key.len()!=32{return Err("Invalid key length".into());}Ok(key)
}
fn decrypt(path:&Path,key:&[u8])->Result<Capsule,String>{
    let meta=fs::symlink_metadata(path).map_err(|_|"Cannot read capsule")?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len()>8_000_000{return Err("Invalid capsule file".into());}
    let bytes=fs::read(path).map_err(|_|"Cannot read capsule")?;
    let data=bytes.strip_prefix(HEADER).ok_or("Invalid capsule header")?;
    if data.len()<12+16{return Err("Invalid capsule length".into());}
    let cipher=Aes256Gcm::new_from_slice(key).map_err(|_|"Invalid key")?;
    let plain=cipher.decrypt(Nonce::from_slice(&data[..12]),Payload{msg:&data[12..],aad:HEADER}).map_err(|_|"Key incorrect or capsule modified")?;
    serde_json::from_slice(&plain).map_err(|_|"Invalid authenticated capsule".into())
}
#[cfg(feature="clear-bootstrap")]
fn run_update(capsule:&Path,ipa:&Path)->Result<(),String>{
    let key=read_key()?;let c=decrypt(capsule,&key)?;let request=validate(&c)?;
    let team=clearsign::upgrade_team(&request)?;
    let meta=fs::symlink_metadata(ipa).map_err(|_|"Cannot read IPA")?;
    if !meta.is_file()||meta.file_type().is_symlink()||meta.len()>16*1024*1024{return Err("Invalid IPA file".into());}
    eprintln!("Esta operación reemplaza ClearWidget con el mismo equipo e identificadores. Puede solicitar un certificado si no hay una clave local válida; nunca revoca uno. No inicia sesión con contraseña. Escribí ACTUALIZAR para autorizar.");
    let mut answer=String::new();io::stdin().lock().read_line(&mut answer).map_err(|_|"Cannot read confirmation")?;
    if answer.trim()!="ACTUALIZAR"{return Err("Cancelled".into());}
    let temp=stage(&c)?;
    let root=temp.0.parent().ok_or("Missing private root")?;
    let key_path=root.join(format!("update-key-{team}.der"));
    let signing_key=match fs::symlink_metadata(&key_path){
        Ok(m)=>{
            if !m.is_file()||m.file_type().is_symlink()||m.permissions().mode()&0o077!=0||!(512..=4096).contains(&m.len()){return Err("Unsafe local signing key".into());}
            fs::read(&key_path).map_err(|_|"Cannot read local key")?
        },
        Err(e) if e.kind()==io::ErrorKind::NotFound=>{
            let key=rsa::RsaPrivateKey::new(&mut rand::rngs::OsRng,2048).map_err(|_|"Cannot generate local key")?;
            let der=key.to_pkcs8_der().map_err(|_|"Cannot encode local key")?.as_bytes().to_vec();
            let mut f=fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&key_path).map_err(|_|"Cannot preserve local signing key")?;
            f.write_all(&der).map_err(|_|"Cannot write local key")?;f.sync_all().map_err(|_|"Cannot save local key")?;
            der
        },
        Err(_)=>return Err("Cannot inspect local key".into()),
    };
    let bytes=fs::read(ipa).map_err(|_|"Cannot read IPA")?;
    for (name,data) in [("signing-key.der",signing_key),("bootstrap.ipa",bytes)]{
        let mut f=fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(temp.0.join(name)).map_err(|_|"Cannot stage update")?;
        f.write_all(&data).map_err(|_|"Cannot stage update")?;
    }
    let result=clearsign::upgrade_existing(temp.0.to_str().ok_or("Invalid path")?,&request)?;
    println!("Update result: {result}");
    println!("Abrí ClearWidget y verificá la versión. Si perdió la sesión, importá el respaldo cifrado. La clave de firma nueva queda solo en el directorio privado de Open Minis.");
    Ok(())
}
fn run()->Result<(),String>{
    let args:Vec<_>=std::env::args_os().skip(1).collect();
    #[cfg(feature="clear-bootstrap")]
    if args.len()==3 && args[0].to_str()==Some("update"){return run_update(Path::new(&args[1]),Path::new(&args[2]));}
    if args.len()!=1{return Err("Usage: clearrecovery <local-encrypted-capsule> | clearrecovery update <capsule> <original-ipa>".into());}
    let key=read_key()?;let c=decrypt(Path::new(&args[0]),&key)?;let request=validate(&c)?;let temp=stage(&c)?;
    // No private key, no certificate requests/revocations, no App ID creation.
    // Does not depend on the main app running. The same conservative renew
    // adapter checks both profiles before installing either.
    let expiry=clearsign::recover_profiles(temp.0.to_str().ok_or("Invalid path")?,&request)?;
    println!("Device service accepted both profiles; reported minimum expiry (Unix): {expiry}");
    println!("Verify in iOS that the app and widget open. A receipt alone does not prove recovery.");
    Ok(())
}
fn main(){if let Err(message)=run(){eprintln!("ClearRecovery stopped: {message}");std::process::exit(1);}}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn refuses_paths(){assert!(!allowed("../account.plist"));assert!(!allowed("signing-key.der"));assert!(allowed("pairing.plist"));}
    #[test]fn refuses_invalid_capsule(){let c=Capsule{version:1,request:String::new(),files:BTreeMap::new()};assert!(validate(&c).is_err());}
}
