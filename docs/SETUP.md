# One-time setup (all doable from an Android phone)

You need three things from Roblox and two places to put them in GitHub.
Nothing is installed on your PC.

> Use Chrome on your phone. If a GitHub or Creator Hub button is missing, open
> Chrome's ⋮ menu and tick **Desktop site**.

## 1. Your experience's IDs (Roblox Creator Hub)

1. Open **https://create.roblox.com/dashboard/creations** and sign in.
2. Find the experience you want to use for playtesting. Tap its **⋯** menu:
   - **Copy Universe ID** → this is `ROBLOX_UNIVERSE_ID`
   - **Copy Start Place ID** → this is `ROBLOX_PLACE_ID`

   (Alternative: open the experience; the address bar shows
   `…/experiences/<UNIVERSE_ID>/overview`. Then **Places** → tap the start place;
   the address shows `…/places/<PLACE_ID>/configure`.)
3. On the experience's overview, confirm it says **Private**. Leave it private.
4. In the experience's settings, make sure **Phone** and **Tablet** are allowed
   devices.

⚠️ Deploying **replaces the current contents of that place**. Older versions stay
in Creator Hub → Places → *Version History* if you ever need one back. Use a
spare/test experience if the current one matters to you.

> Don't have an experience? Roblox doesn't let you create a new one from a phone
> yet. Most accounts already have a starter place under Creations — that works.

## 2. An Open Cloud API key (Roblox Creator Hub)

1. Open **https://create.roblox.com/dashboard/credentials** → **Create API Key**.
2. Name: `tumble-circuit-deploy`.
3. **Access Permissions** — add these API systems, each for **your experience**:
   - `universe-places` → operation **Write**
   - `assets` → operations **Read** and **Write**
4. **Security → Accepted IP Addresses** → add `0.0.0.0/0`
   (GitHub's servers change IP every run; without this every deploy is rejected).
5. Optional: set an expiration date.
6. **Save & Generate Key** → **Copy Key to Clipboard**. It is shown only once.

Keep the key out of chats, files and screenshots. It only goes into GitHub Secrets.

## 3. Put them into GitHub

In the repository: **Settings → Secrets and variables → Actions**.

| Tab | Name | Value |
| --- | --- | --- |
| **Secrets** → New repository secret | `ROBLOX_API_KEY` | the key you copied |
| **Variables** → New repository variable | `ROBLOX_UNIVERSE_ID` | the Universe ID |
| **Variables** → New repository variable | `ROBLOX_PLACE_ID` | the Start Place ID |

The IDs are not secret (they appear in the game's web address), so they are
variables — that lets the deploy log print the links to your game. The key is a
secret: GitHub hides it from logs and nobody can read it back, including you.

## 4. Deploy

1. **Actions** tab → **Deploy to Roblox (private playtest)** → **Run workflow**.
2. Leave `version_type` = **Published** and `allow_public` **unticked** → **Run workflow**.
3. Wait ~2 minutes. Open the run: the summary shows the version number and the
   links to play.

Every push to `main` also runs **Build**, which validates and assembles the place
and attaches it as a downloadable artifact (`TumbleCircuit-place`) — without
publishing anything.

## Troubleshooting

| Deploy says | Fix |
| --- | --- |
| `Missing configuration` | One of the three names above is missing or misspelled. |
| `Could not confirm the experience is private (HTTP 401/403)` | Key is wrong/expired, or `0.0.0.0/0` isn't in Accepted IP Addresses. If both are right, also add the `universe` API system with **Read** for the experience. |
| `… HTTP 404` | Universe ID and Place ID are swapped or from different experiences. |
| `Place Publishing API failed (HTTP 403)` | The key needs `universe-places` → **Write** for this experience. |
| `The experience is PUBLIC` | Make it private in Creator Hub, or tick `allow_public` if you really mean it. |
| `HTTP 409` | The place is open in a Team Create session somewhere; close it. |
