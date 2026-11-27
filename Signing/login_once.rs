// Appended to verified vendor GSA. Fixed route; one explicit 2FA response.
fn clear_login_error(stage: &'static str, e: LoginError) -> &'static str {
    match e {
        LoginError::WrongPassword(_) => "auth_credentials_or_throttled",
        LoginError::IdentityRefused(_) => "auth_identity_refused",
        LoginError::ServiceRefused(_) => "auth_service_refused",
        LoginError::Stop(_) => "auth_security_stop",
        LoginError::Cancelled => "auth_cancelled",
        LoginError::Other(ref reason) => match reason.as_str() {
            "clear_2fa_incorrect" => "auth_code_rejected",
            "clear_2fa_rate_limited" => "auth_rate_limited",
            "clear_2fa_rejected" => "auth_verification_refused",
            "clear_2fa_invalid_response" => "auth_verification_response",
            _ => stage,
        }
    }
}
// No raw server body, account, code, or token in the public diagnostic.
pub async fn clearsign_login_once(email:&str,password:&str,server:&str,ask:&CodeAsker)->Result<(), &'static str>{
    if !SERVERS.contains(&server){return Err("auth_route_invalid");}
    let advertised=Anisette::advertised(&http_client(),server).await.map_err(|_|"auth_anisette_unavailable")?;
    let gs=GrandSlam::connect(server,&advertised,Claim::Advertised).await.map_err(|_|"auth_connection_failed")?;
    let email=email.trim().to_lowercase();
    let stage=srp_login(&gs,&email,password).await.map_err(|e|clear_login_error("auth_initial_handshake",e))?;
    let stage=match stage{
        Stage::LoggedIn(spd)=>Stage::LoggedIn(spd),
        Stage::TrustedDevice{ref spd,sent}=>{
            trusted_device(&gs,spd,sent,ask).await.map_err(|e|clear_login_error("auth_verification_transport",e))?;
            srp_login(&gs,&email,password).await.map_err(|e|clear_login_error("auth_post_verification",e))?
        },
        Stage::Sms(ref spd)=>{
            sms(&gs,spd,ask).await.map_err(|e|clear_login_error("auth_verification_transport",e))?;
            srp_login(&gs,&email,password).await.map_err(|e|clear_login_error("auth_post_verification",e))?
        }
    };
    let Stage::LoggedIn(spd)=stage else{return Err("auth_additional_verification");};
    let s=|k:&str|spd.get(k).and_then(Value::as_string).unwrap_or("").to_string();
    let b=|k:&str|spd.get(k).and_then(Value::as_data).map(<[u8]>::to_vec).unwrap_or_default();
    let mut account=Account{email,adsid:s("adsid"),idms_token:s("GsIdmsToken"),session_key:b("sk"),c:b("c"),first_name:s("fn"),last_name:s("ln"),xcode_token:String::new(),xcode_expiry_ms:0};
    if account.adsid.is_empty() || account.idms_token.is_empty() || account.session_key.len()!=32 || account.c.is_empty(){return Err("auth_session_invalid");}
    app_token(&gs,&mut account).await.map_err(|e|clear_login_error("auth_token_failed",e))?;
    if account.xcode_token.is_empty() || !account.token_fresh(){return Err("auth_token_invalid");}
    state::write_private(&state::path("anisette-server"),format!("{}\n{}",server,Claim::Advertised.name()).as_bytes()).map_err(|_|"auth_storage_failed")?;
    account.save().map_err(|_|"auth_storage_failed")?;
    Ok(())
}
#[cfg(test)]
mod clear_login_tests {
    use super::*;
    #[test] fn diagnostics_do_not_leak_payloads() {
        assert_eq!(clear_login_error("auth_token_failed",LoginError::Other("secret payload".into())),"auth_token_failed");
        assert_eq!(clear_login_error("auth_initial_handshake",LoginError::WrongPassword("private".into())),"auth_credentials_or_throttled");
        assert_eq!(clear_login_error("auth_verification_transport",LoginError::Other("clear_2fa_incorrect".into())),"auth_code_rejected");
    }
}
