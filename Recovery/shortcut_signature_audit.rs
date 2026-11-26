
// Check actual signature blobs, not the pre-signing entitlement plan alone.
pub fn verify_shortcut_trial(ipa:&Ipa,plan:&Plan)->Result<(),String>{
    fn word(s:&[u8],o:usize,le:bool)->Option<usize>{
        let a:[u8;4]=s.get(o..o.checked_add(4)?)?.try_into().ok()?;
        Some(if le{u32::from_le_bytes(a)}else{u32::from_be_bytes(a)} as usize)
    }
    fn signature(m:&[u8])->Option<&[u8]>{
        let mut o=32usize;
        for _ in 0..word(m,16,true)?{
            let cmd=word(m,o,true)?;let len=word(m,o.checked_add(4)?,true)?;
            if len<8{return None}
            if cmd==0x1d{
                if len<16{return None}
                let a=word(m,o.checked_add(8)?,true)?;let n=word(m,o.checked_add(12)?,true)?;
                return m.get(a..a.checked_add(n)?)
            }
            o=o.checked_add(len)?;
        }None
    }
    fn slot(s:&[u8],kind:usize,magic:usize)->Option<&[u8]>{
        if word(s,0,false)?!=0xfade0cc0{return None}
        let len=word(s,4,false)?;let s=s.get(..len)?;
        let count=word(s,8,false)?;if count>(s.len().checked_sub(12)?)/8{return None}
        let mut found=None;
        for i in 0..count{let o=12+i*8;if word(s,o,false)?==kind{
            if found.is_some(){return None}
            let a=word(s,o+4,false)?;if word(s,a,false)?!=magic{return None}
            let n=word(s,a.checked_add(4)?,false)?;if n<8{return None}
            found=Some(s.get(a..a.checked_add(n)?)?);
        }}found
    }
    let mut shared:Option<String>=None;let mut count=0;
    for b in ipa.bundles()?{
        let expected=plan.bundles.get(&b.dir).ok_or("Missing signing plan")?;
        let app=expected.entitlements.get("application-identifier").and_then(Value::as_string).ok_or("Missing app identifier")?;
        let prefix=app.split_once('.').ok_or("Invalid app identifier")?.0;
        let group=format!("{prefix}.com.clearwidget.bridge");
        if shared.as_ref().is_some_and(|g|g!=&group){return Err("Shared group differs".into())}
        shared=Some(group.clone());count+=1;
        let groups=expected.entitlements.get("keychain-access-groups").and_then(Value::as_array).ok_or("Missing groups")?;
        if !groups.iter().any(|x|x.as_string()==Some(group.as_str())){return Err("Missing concrete shared group".into())}
        let main=ipa.files.get(&format!("{}/{}",b.dir,b.executable)).ok_or("Missing executable")?;
        let m=thin_arm64(&main.data).ok_or("Missing ARM64")?;
        let s=signature(m).ok_or("Missing signature")?;
        let xml=slot(s,5,0xfade7171).ok_or("Missing XML entitlements")?;
        let der=slot(s,7,0xfade7172).ok_or("Missing DER entitlements")?;
        let cd=slot(s,0,0xfade0c02).ok_or("Missing CodeDirectory")?;
        let actual:Dictionary=plist::from_bytes(&xml[8..]).map_err(|_|"Invalid XML entitlements")?;
        if actual!=expected.entitlements||der[8..]!=codesign::der_entitlements(&expected.entitlements)?[..]{return Err("Signed entitlements mismatch".into())}
        let hash_off=word(cd,16,false).ok_or("Invalid CodeDirectory")?;
        if word(cd,24,false).unwrap_or(0)<7||cd.get(36)!=Some(&32)||cd.get(37)!=Some(&2){return Err("Unexpected CodeDirectory format".into())}
        for (n,blob) in [(5usize,xml),(7usize,der)]{
            let start=hash_off.checked_sub(n*32).ok_or("Invalid hash offset")?;
            if cd.get(start..start+32)!=Some(sha2::Sha256::digest(blob).as_slice()){return Err("Entitlement hash mismatch".into())}
        }
        let p=ipa.files.get(&format!("{}/embedded.mobileprovision",b.dir)).ok_or("Missing profile")?;
        if p.data!=expected.profile{return Err("Embedded profile differs".into())}
    }
    if count!=2{return Err("Expected exactly two signed bundles".into())}
    Ok(())
}
