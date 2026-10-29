# Brewskis Shift Lists

The staff app for JT Brewski's Pub: shift checklists by role, inventory counts against par, supplier order deadlines, and a searchable activity log. Everyone logs in with a 4–6 digit number. It installs on phones like a regular app.

## What's in here

| Folder | What it is |
|---|---|
| `site/` | The app itself (what people open on their phones) |
| `supabase/schema.sql` | The database: tables, logins, and every action the app can take |
| `supabase/seed.sql` | Your current roles, team, 50 checklist tasks, inventory lists and suppliers |
| `.github/workflows/pages.yml` | Publishes `site/` to GitHub Pages every time you push |

## Setup (about 20 minutes)

### 1. Create the database in Supabase

1. Sign up at [supabase.com](https://supabase.com) and create a **New project**. Name it `brewskis`, pick the **East US** region, and save the database password somewhere safe.
2. Open **SQL Editor → New query**. Paste all of `supabase/schema.sql` and press **Run**.
3. Open another new query. Paste all of `supabase/seed.sql` and press **Run**. This brings over your roles, team, checklists and suppliers.
4. Open another new query and give yourself a login number (pick your own 4–6 digits):

   ```sql
   select admin_set_pin('Aidan', '4821');
   ```

5. Go to **Project Settings → API Keys** (or **Data API**) and copy two things: the **Project URL** and the **publishable** key (it starts with `sb_publishable_`; the older "anon public" key also works).

### 2. Connect the app to the database

Open `site/config.js` and paste in those two values:

```js
window.BREWSKIS_CONFIG = {
  supabaseUrl: "https://abcdefgh.supabase.co",
  supabaseAnonKey: "sb_publishable_..."
};
```

These are safe to publish. The database only lets that key call the app's own actions, and every action checks the login number first.

### 3. Publish on GitHub Pages

1. Create a new repository on GitHub, for example `brewskis-shift-lists`, and add these files to it (keep the folder structure).
2. In the repository, go to **Settings → Pages** and set **Source** to **GitHub Actions**.
3. Push to `main` (or open **Actions → Publish the app → Run workflow**). After a minute the app is live at `https://YOUR-USERNAME.github.io/brewskis-shift-lists/`.

### 4. Install it on phones and tablets

- **iPhone or iPad:** open the link in Safari, tap **Share**, then **Add to Home Screen**.
- **Android:** open the link in Chrome and tap **Install** in the header (or **Install app** in Chrome's menu).

It opens full screen with the Brewski's logo as its icon.

### 5. Give everyone else a number

Log in with your number, open the **Team** tab, and tap **Assign number** for Tom, Mandy, Brian and Jill. The app shows each number once so you can tell them.

## Good to know

- **Who can do what.** Only people with the Manager role see the Team tab, order deadlines, suppliers and pars. The server enforces this, not just the screen.
- **Logins.** Numbers are stored as one-way hashes. Changing or turning off someone's number logs them out everywhere. After 15 wrong tries in a minute, logins pause for a minute. Phones log out on their own 16 hours after logging in.
- **The last manager.** The app won't let you remove the last manager who can log in. If every manager number is ever lost, run `select admin_set_pin('Name', '1234');` in the SQL Editor.
- **Offline.** The app still opens without signal and shows the last lists it loaded. Saving changes needs a connection.
- **Activity history** is kept for 60 days.
- **Supabase's free plan** pauses a project after about a week with no use. Daily use at the pub keeps it awake; if it ever pauses, press **Restore** in Supabase.
- **Shift day** rolls over at 5 AM Eastern, so a closing shift after midnight still counts as the same day.

## Making changes later

Database updates live in `supabase/migrations/`. A new database's `schema.sql` already includes them; an existing database needs each new migration run once in the SQL Editor before the matching app update is published.


Edit the files in `site/`, then change `VERSION` at the top of `site/sw.js` (for example `brewskis-v2`) so installed copies pick up the update, and push. Phones get the new version the next time the app is opened twice.
