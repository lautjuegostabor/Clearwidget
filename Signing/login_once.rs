// Appended to the pinned gsa module. Reuses its SRP and 2FA primitives; no server rotation.
pub async fn clearsign_login_once(email:&str,password:&str,server:&str,ask:&CodeAsker)->Result<(),LoginError>{
    if !SERVERS.contains(&server){return Err(LoginError::Stop("Unapproved anisette route".into()));}
    let advertised=Anisette::advertised(&http_client(),server).await.map_err(other)?;
    let gs=GrandSlam::connect(server,&advertised,Claim::Advertised).await.map_err(other)?;
    let email=email.trim().to_lowercase();
    let stage=srp_login(&gs,&email,password).await?;
    let stage=match stage{
        Stage::LoggedIn(spd)=>Stage::LoggedIn(spd),
        Stage::TrustedDevice{ref spd,sent}=>{trusted_device(&gs,spd,sent,ask).await?;srp_login(&gs,&email,password).await?},
        Stage::Sms(ref spd)=>{sms(&gs,spd,ask).await?;srp_login(&gs,&email,password).await?}
    };
    let Stage::LoggedIn(spd)=stage else{return Err(LoginError::Stop("Additional authentication required; stopped".into()));};
    let s=|k:&str|spd.get(k).and_then(Value::as_string).unwrap_or("").to_string();
    let b=|k:&str|spd.get(k).and_then(Value::as_data).map(<[u8]>::to_vec).unwrap_or_default();
    let mut account=Account{email,adsid:s("adsid"),idms_token:s("GsIdmsToken"),session_key:b("sk"),c:b("c"),first_name:s("fn"),last_name:s("ln"),xcode_token:String::new(),xcode_expiry_ms:0};
    app_token(&gs,&mut account).await?;
    state::write_private(&state::path("anisette-server"),format!("{}\n{}",server,Claim::Advertised.name()).as_bytes()).map_err(other)?;
    account.save().map_err(other)?;
    Ok(())
}
