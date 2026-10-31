/**
 * JT Brewski's party form -> staff app.
 *
 * Sends each new answer on the "Plan Your Party at JT Brewski's Pub!" Google Form to the staff app,
 * where it shows up as a party inquiry on the Events tab and managers get an alert.
 *
 * Setup (once):
 *   1. Open the form in edit mode > the three-dot menu (top right) > Apps Script.
 *   2. Replace everything in Code.gs with this file, with FORM_KEY filled in. Save.
 *   3. Pick "setup" in the function menu at the top and press Run. Allow the permissions it asks for.
 *      That turns it on and sends any inquiries from the last 30 days whose dates haven't passed.
 * Running setup again is safe: nothing is ever added twice.
 *
 * FORM_KEY is a password for the app. Keep it out of anything public (it is not in the GitHub copy).
 */
const APP_URL = 'https://xlvukvolpmsgyhtvbtut.supabase.co/rest/v1/rpc/api_party_form';
const PUBLIC_KEY = 'sb_publishable_To80jccXZGOOMIuH0fnV5w_QPaboLBu';   // public by design (same as the app's)
const FORM_KEY = 'PASTE-THE-FORM-KEY-HERE';

/** Runs on every new form answer. */
function onPartyInquiry(e) {
  send_(e.response);
}

/** Run once by hand: turns on the trigger and sends recent inquiries. */
function setup() {
  const form = FormApp.getActiveForm();
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'onPartyInquiry')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('onPartyInquiry').forForm(form).onFormSubmit().create();
  const since = new Date(Date.now() - 30 * 24 * 3600 * 1000);
  let sent = 0;
  form.getResponses(since).forEach(r => { if (send_(r)) sent++; });
  Logger.log('Connected. Sent ' + sent + ' recent inquiries for upcoming dates.');
}

function send_(resp) {
  const answers = {};
  resp.getItemResponses().forEach(ir => {
    const v = ir.getResponse();
    answers[ir.getItem().getTitle().trim().toLowerCase()] = Array.isArray(v) ? v.join(', ') : String(v || '');
  });
  // matches by question wording, so small edits to the questions still work
  const pick = (...words) => {
    for (const w of words) for (const k in answers) if (k.indexOf(w) !== -1) return answers[k];
    return '';
  };
  const data = {
    response_id: resp.getId(),
    submitted_at: resp.getTimestamp().toISOString(),
    name: pick('full name', 'name'),
    phone: pick('phone'),
    email: pick('email') || resp.getRespondentEmail() || '',
    kind: pick('type of event', 'occasion'),
    date: pick('desired date', 'preferred date'),
    backup: pick('back up date', 'backup date', 'back-up date'),
    start: pick('start time'),
    guests: pick('guest count', 'guests', 'how many'),
    package: pick('which option', 'package'),
    notes: pick('anything else', 'notes'),
  };
  const res = UrlFetchApp.fetch(APP_URL, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: PUBLIC_KEY },
    payload: JSON.stringify({ p_key: FORM_KEY, p_data: data }),
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) {
    Logger.log('The app said no (' + res.getResponseCode() + '): ' + res.getContentText());
    return false;
  }
  return res.getContentText() !== 'null';   // null = that date has passed, so it was skipped
}
