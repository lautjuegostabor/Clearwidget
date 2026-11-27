#!/usr/bin/env python3
"""Staged vendor patch; no raw 2FA payload, no automatic code retry."""
from pathlib import Path
import sys
def replace(s,a,b):
    if s.count(a)!=1: raise ValueError("Unexpected anchor: "+a[:100])
    return s.replace(a,b,1)
def patch(s):
    start=s.index("async fn trusted_device(")
    end=s.index("pub async fn app_token(",start)
    s=s[:start]+'''// An empty HTTP 200/204 is possible; the subsequent SRP must still prove completion.
// Reject structured errors, unexpected bodies and all non-success HTTP responses.
fn clear_verify_response(status:u16, bytes:&[u8])->Result<(),LoginError>{
    if status==429 {return Err(other("clear_2fa_rate_limited"));}
    if !bytes.is_empty(){
        let code = if let Ok(d)=plist::from_bytes::<Dictionary>(bytes) {
            d.get("ec").and_then(Value::as_signed_integer).or_else(||d.get("Status").and_then(Value::as_dictionary).and_then(|v|v.get("ec")).and_then(Value::as_signed_integer))
        } else if let Ok(d)=serde_json::from_slice::<serde_json::Value>(bytes) {
            d.get("ec").and_then(|v|v.as_i64()).or_else(||d.pointer("/Status/ec").and_then(|v|v.as_i64()))
        } else {
            return Err(other(if status==200 || status==204 {"clear_2fa_invalid_response"} else {"clear_2fa_rejected"}));
        };
        if code==Some(-21669){return Err(other("clear_2fa_incorrect"));}
        if code.is_some_and(|v|v!=0){return Err(other("clear_2fa_rejected"));}
        if code.is_none() && status==200 {return Err(other("clear_2fa_invalid_response"));}
    }
    if status==200 || status==204 {Ok(())} else {Err(other("clear_2fa_rejected"))}
}
async fn trusted_device(gs: &GrandSlam, spd: &Dictionary, sent: bool, ask: &CodeAsker) -> Result<(), LoginError> {
    let send = gs.url("trustedDeviceSecondaryAuth").map_err(other)?;
    let validate = gs.url("validateCode").map_err(other)?;
    if !sent {
        let status=gs.http.get(&send).headers(second_factor_headers(gs,spd,false).await?).send().await.map_err(other)?.status().as_u16();
        if status==429{return Err(other("clear_2fa_rate_limited"));}
        // A trusted-device push may arrive even on HTTP 403.
        if !(200..300).contains(&status) && status!=403{return Err(other("clear_2fa_rejected"));}
    }
    let code=ask(CodeKind::TrustedDevice,None).await.ok_or(LoginError::Cancelled)?;
    let response=gs.http.get(&validate).headers(second_factor_headers(gs,spd,false).await?).header("security-code",code.trim()).send().await.map_err(other)?;
    let status=response.status().as_u16();
    let bytes=response.bytes().await.map_err(other)?;
    clear_verify_response(status,&bytes)
}
async fn sms(gs: &GrandSlam, spd: &Dictionary, ask: &CodeAsker) -> Result<(), LoginError> {
    let response=gs.http.get("https://gsa.apple.com/auth").headers(second_factor_headers(gs,spd,true).await?).send().await.map_err(other)?;
    if response.status().as_u16()==429{return Err(other("clear_2fa_rate_limited"));}
    if !response.status().is_success(){return Err(other("clear_2fa_rejected"));}
    let numbers:serde_json::Value=response.json().await.map_err(other)?;
    let id=numbers.pointer("/trustedPhoneNumbers/0/id").and_then(|v|v.as_u64()).ok_or_else(||other("clear_2fa_invalid_response"))?;
    let body=serde_json::json!({"phoneNumber":{"id":id},"mode":"sms"});
    let response=gs.http.put("https://gsa.apple.com/auth/verify/phone").headers(second_factor_headers(gs,spd,true).await?).json(&body).send().await.map_err(other)?;
    if response.status().as_u16()==429{return Err(other("clear_2fa_rate_limited"));}
    if !response.status().is_success(){return Err(other("clear_2fa_rejected"));}
    let code=ask(CodeKind::Sms,None).await.ok_or(LoginError::Cancelled)?;
    let body=serde_json::json!({"securityCode":{"code":code.trim()},"phoneNumber":{"id":id},"mode":"sms"});
    let response=gs.http.post("https://gsa.apple.com/auth/verify/phone/securitycode").headers(second_factor_headers(gs,spd,true).await?).json(&body).send().await.map_err(other)?;
    let status=response.status().as_u16();
    let bytes=response.bytes().await.map_err(other)?;
    clear_verify_response(status,&bytes)
}
#[cfg(test)]
mod clear_verify_tests{
    use super::*;
    #[test] fn fails_closed(){
        assert!(clear_verify_response(403,b"").is_err());
        assert!(clear_verify_response(429,b"").is_err());
        assert!(clear_verify_response(200,b"not a plist").is_err());
        assert!(clear_verify_response(200,br#"{"ec":-21669}"#).is_err());
        assert!(clear_verify_response(200,br#"{"Status":{"ec":-20209}}"#).is_err());
        assert!(clear_verify_response(200,b"{}").is_err());
        assert!(clear_verify_response(200,br#"{"ec":0}"#).is_ok());
        assert!(clear_verify_response(204,b"").is_ok());
    }
}
'''+s[end:]
    # Stop on repair/unknown additional authentication, rather than treating as logged in.
    s=replace(s,'''        Some("repair") | None => {}
        Some(other_step) => logf!("gsa: unknown extra step {other_step}; continuing"),''','''        None => {}
        Some(_) => return Err(LoginError::Stop("Additional account action required".into())),''')
    return s
if __name__=="__main__":
    p=Path(sys.argv[1])/"src/apple/gsa.rs"
    p.write_text(patch(p.read_text()))
