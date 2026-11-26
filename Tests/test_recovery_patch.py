import importlib.util, pathlib, unittest
P=pathlib.Path(__file__).resolve().parents[1]/'Recovery/prepare_signer.py'
spec=importlib.util.spec_from_file_location('prepare_signer',P);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class TestPatch(unittest.TestCase):
    def fixture(self):
        return '''    let main = ipa.main_app()?;
    if !opts.icon.is_empty() {
    }
    apps.sort_by_key(|b| b.depth());
    status("Registering this iPhone".into());
    portal.ensure_device(team, ctx.udid, ctx.device_name).await.map_err(|e| e.to_string())?;
    fit_app_ids(ctx, &apps, &main, &mut ids, &existing, status).await?;
    let mut plan_bundles = HashMap::new();
        entitlements.insert("com.apple.developer.team-identifier".into(), Value::String(team.into()));
        plan_bundles.insert'''
    def test_restricts_both_bundles(self):
        s=m.patch_install(self.fixture()); self.assertIn('main.id != "com.clearwidget.app"',s); self.assertIn('opts.remove_extensions',s); self.assertIn('apps.len() != 2',s); self.assertIn('crate::bridge_entitlements::apply',s)
    def test_refuses_missing_or_duplicate_anchors(self):
        for s in ['',self.fixture()*2,self.fixture().replace('apps.sort_by_key','apps.sort')]:
            with self.assertRaises(ValueError):m.patch_install(s)
if __name__=='__main__':unittest.main()
