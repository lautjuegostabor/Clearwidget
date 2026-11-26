//! Narrow, profile-authorized Keychain group for ClearWidget only.
use plist::{Dictionary, Value};

pub fn apply(profile: &Dictionary, signed: &mut Dictionary, effective_id: &str) -> Result<String, String> {
    let app = profile.get("application-identifier").and_then(Value::as_string)
        .ok_or("Missing application identifier in profile")?;
    let (prefix, bundle) = app.split_once('.').ok_or("Invalid application identifier")?;
    if prefix.is_empty() || !prefix.bytes().all(|x| x.is_ascii_alphanumeric()) || bundle != effective_id {
        return Err("ClearWidget profile does not match the requested identifier".into());
    }
    if signed.get("application-identifier").and_then(Value::as_string) != Some(app) { return Err("The signed identifier would differ from the profile".into()); }
    let group = format!("{prefix}.com.clearwidget.bridge");
    let wildcard = format!("{prefix}.*");
    let allowed = profile.get("keychain-access-groups").and_then(Value::as_array)
        .ok_or("Apple profile has no Keychain access groups")?;
    let permits = |s: &str| allowed.iter().filter_map(Value::as_string)
        .any(|v| v == s || (v == wildcard.as_str() && s.starts_with(&format!("{prefix}."))));
    if !permits(app) || !permits(&group) {
        return Err("Apple did not authorize the ClearWidget shared Keychain group; not signing".into());
    }
    // Never claim a wildcard. Default group first, narrowly shared group second.
    // Preserve exact groups already authorized by this profile (including com.apple.token).
    let mut result = vec![Value::String(app.to_owned()), Value::String(group)];
    for x in allowed {
        if let Some(s) = x.as_string() {
            if !s.contains('*') && !result.contains(x) { result.push(x.clone()); }
        }
    }
    signed.insert("keychain-access-groups".into(), Value::Array(result));
    Ok(prefix.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(id: &str, groups: &[&str]) -> Dictionary {
        let mut d = Dictionary::new();
        d.insert("application-identifier".into(), Value::String(id.into()));
        d.insert("keychain-access-groups".into(), Value::Array(groups.iter().map(|x| Value::String((*x).into())).collect())); d
    }
    #[test] fn expands_authorized_wildcard_only() {
        let p = profile("TEAM.com.clearwidget.app", &["TEAM.*", "com.apple.token"]);
        let mut s = p.clone(); apply(&p, &mut s, "com.clearwidget.app").unwrap();
        assert_eq!(s["keychain-access-groups"].as_array().unwrap(), &vec![Value::String("TEAM.com.clearwidget.app".into()), Value::String("TEAM.com.clearwidget.bridge".into()), Value::String("com.apple.token".into())]);
    }
    #[test] fn refuses_unapproved_or_other_bundle() {
        let p = profile("TEAM.com.clearwidget.app", &["TEAM.com.clearwidget.app"]);
        assert!(apply(&p, &mut p.clone(), "com.clearwidget.app").is_err());
        let p = profile("TEAM.com.clearwidget.app", &["TEAM.*"]);
        assert!(apply(&p, &mut p.clone(), "com.clearwidget.app.widget").is_err());
    }
}
