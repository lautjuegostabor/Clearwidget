import plistlib as p, uuid, pathlib, json, zipfile
A=[]
def act(name, params=None, output=None, native=True):
    i=str(uuid.uuid4()).upper()
    v=dict(params or {}, UUID=i)
    if output:v['CustomOutputName']=output
    A.append({'WFWorkflowActionIdentifier':('is.workflow.actions.' if native else '')+name,'WFWorkflowActionParameters':v})
    return {'Type':'ActionOutput','OutputUUID':i,'OutputName':output or name}
def ref(v):return {'WFSerializationType':'WFTextTokenAttachment','Value':v}
def detail(w,key,label):return act('properties.weather.conditions',{'WFInput':ref(w),'WFContentItemPropertyName':key},label)
def item(w,n,label):return act('getitemfromlist',{'WFInput':ref(w),'WFItemSpecifier':'Item At Index','WFItemIndex':n},label)
loc=act('getcurrentlocation',{},'Ubicación')
current=act('weather.currentconditions',{'WFWeatherCustomLocation':ref(loc)},'Clima actual')
hourly=act('weather.forecast',{'WFWeatherCustomLocation':ref(loc),'WFWeatherForecastType':'Hourly'},'Pronóstico horario')
daily=act('weather.forecast',{'WFWeatherCustomLocation':ref(loc),'WFWeatherForecastType':'Daily'},'Pronóstico diario')
today=item(daily,1,'Hoy')
tomorrow=item(daily,2,'Mañana')
params={
'location':ref(loc),
'currentTemperature':ref(detail(current,'Temperature','Temperatura actual')),
'currentCondition':ref(detail(current,'Condition','Condición actual')),
'hourlyDates':ref(detail(hourly,'Date','Fechas por hora')),
'hourlyTemperatures':ref(detail(hourly,'Temperature','Temperaturas por hora')),
'hourlyConditions':ref(detail(hourly,'Condition','Condiciones por hora')),
'todayLow':ref(detail(today,'Low','Mínima de hoy')),
'tomorrowHigh':ref(detail(tomorrow,'High','Máxima de mañana'))}
# Verify the exact action and parameter identifiers against the compiled IPA.
with zipfile.ZipFile('/tmp/cw-ipa/ClearWidget-v0.5.10.ipa') as z:
    m=json.loads(z.read('Payload/ClearWidget.app/Metadata.appintents/extract.actionsdata'))
    intent=m['actions']['NativeAppleWeatherIntent']
    assert intent['isDiscoverable']
    assert set(params)=={x['name'] for x in intent['parameters']}
# Team identity is assigned by the personal sideload signer. It is deliberately
# not fabricated or set to an unrelated developer. iOS resolution is untested.
params['AppIntentDescriptor']={'BundleIdentifier':'com.clearwidget.app','Name':'ClearWidget','AppIntentIdentifier':intent['identifier']}
act('com.clearwidget.app.'+intent['identifier'],params,native=False)
wf={'WFWorkflowClientVersion':'4000','WFWorkflowMinimumClientVersion':1200,'WFWorkflowMinimumClientVersionString':'1200','WFWorkflowIcon':{'WFWorkflowIconStartColor':1440408063,'WFWorkflowIconGlyphNumber':61440},'WFWorkflowTypes':[],'WFWorkflowInputContentItemClasses':[],'WFWorkflowActions':A}
seen=set()
def check(x):
    if isinstance(x,dict):
        if x.get('Type')=='ActionOutput': assert x['OutputUUID'] in seen
        for v in x.values():check(v)
    elif isinstance(x,list):
        for v in x:check(v)
for a in A:
    x=a['WFWorkflowActionParameters'];check(x);assert x['UUID'] not in seen;seen.add(x['UUID'])
out=pathlib.Path('/tmp/ClearWidget-Clima.unsigned.shortcut')
out.write_bytes(p.dumps(wf,fmt=p.FMT_BINARY,sort_keys=False))
assert p.loads(out.read_bytes())==wf
print('Validated',len(A),'actions, references and eight compiled intent fields')
