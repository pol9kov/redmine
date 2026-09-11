# Personal access tokens for the Redmine REST API

Work on [Redmine issue #43881 — *Strengthen Redmine API authentication*](https://www.redmine.org/issues/43881),
pillar 1: **personal access tokens**.

Branch `feature/personal-access-tokens`, forked from tag **6.1.2**.

---

## 1. What the problem actually is

Before this branch, a Redmine user has exactly **one** REST API credential — the API key
(`Token` with `action='api'`, `app/models/token.rb`). That single key has three properties that
make it a poor fit for anything beyond a personal script:

1. **One per user.** `has_one :api_token`. Wiring a second integration means sharing the same
   secret, so revoking one integration revokes all of them.
2. **Stored in plaintext.** `tokens.value` holds the key itself. Anyone with a database dump —
   or a backup, or a replica — holds every user's API credential.
3. **No expiry, no usage trail.** `Token#expired?` exists, but the API key is registered as
   `add_action :api, max_instances: 1, validity_time: nil` (`app/models/token.rb`) — one instance,
   no validity window — and nothing records that a key was ever used. A leaked key stays valid
   until a human notices.

A personal access token is the standard answer to all three: several named credentials per user,
each independently revocable, stored as a digest, with a mandatory lifetime and a last-used mark.

## 2. What this branch does

| | before | after |
|---|---|---|
| credentials per user | 1 | many, each named |
| storage | plaintext `tokens.value` | SHA256 digest only |
| expiry | none | mandatory, validated on create |
| revocation | reset the single key | per token, independent |
| usage visible | no | `last_used_on`, for the API key too |

The old API key **keeps working unchanged**. `User.find_by_api_credential` tries a personal access
token first and falls back to the API key, so every existing integration, and every existing test
covering it, continues to pass untouched — it only gains two things it never had, an audit trail
row and a last-used mark, both of which are written beside it and not in the `tokens` table. This
was a deliberate constraint: an authentication change that breaks existing clients is not shippable
into a product with a decade of installed base.

### Files

```
app/models/personal_access_token.rb                     the model
db/migrate/20260911120000_create_personal_access_tokens.rb
app/models/user.rb                                      has_many + find_by_api_credential
app/controllers/application_controller.rb               2 call sites, key and HTTP-Basic

app/models/api_auth_event.rb                            audit trail row
db/migrate/20260911130000_create_api_auth_events.rb

app/models/api_credential_usage.rb                      last-used mark, both credential kinds
db/migrate/20260911140000_create_api_credential_usages.rb

app/controllers/my_controller.rb                        list / create / revoke
app/views/my/personal_access_tokens.html.erb            the page
app/views/my/_sidebar.html.erb                          entry point, beside the API key
app/helpers/my_helper.rb                                expiry choices, state label
config/routes.rb  config/locales/en.yml

test/unit/personal_access_token_test.rb
test/unit/api_auth_event_test.rb
test/unit/api_credential_usage_test.rb
test/functional/my_controller_test.rb
test/integration/api_test/authentication_test.rb
test/integration/api_test/disabled_rest_api_test.rb
test/integration/routing/my_test.rb
```

### The management page

*My account → Personal access tokens* (`/my/personal_access_tokens`), reached from the same
sidebar block as the API key and hidden by the same `Setting.rest_api_enabled?` condition — a
personal access token is only ever consumed by the REST path, so it has no meaning when that path
is off.

Three decisions there are worth naming:

- **The new value is rendered, not flashed.** Doorkeeper — vendored in Redmine — shows a freshly
  created client secret by putting it in `flash[:application_secret]` and redirecting. Copying that
  would write the secret into the session cookie. `create_personal_access_token` renders the list
  template directly instead, so the plaintext exists in exactly one response body and nowhere else.
  The cost is that a successful create answers 200 rather than 302.
- **Creating and revoking are behind sudo mode**, like `reset_api_key` and `show_api_key` already
  are. Minting a credential is strictly more dangerous than displaying one. Listing is *not* gated:
  it shows no secret, and a password prompt in front of merely looking at a page is friction with
  nothing bought.
- **Every lookup goes through `User.current.personal_access_tokens`**, so another user's token is
  not reachable by id — it is a 404, not an authorization check that someone can later forget to
  write. Asserted by test.

## 3. How it works

**Value format.** `rmpat_` + 40 hex characters, from `Redmine::Utils.random_hex(20)` — the same
entropy source and the same width Redmine already uses for API keys, so this introduces no new
randomness assumptions. The fixed prefix does two things: it makes the credential recognisable in a
log, a paste or a public repository (secret scanners key on exactly this), and it lets the request
path tell a personal access token from an API key *before* touching the database.

**Storage.** Only `SHA256(value)` is persisted, in `hashed_value`. There is no way back from the
database to the token, which is the point. The plaintext exists on exactly one object — the
instance that generated it, via `#plain_value` — and is shown to the user once. Redmine already
does this for OAuth tokens (`hash_token_secrets` in `config/initializers/30-redmine.rb`), so this
is the existing convention of the codebase, not a new one.

*Why a plain SHA256 and not bcrypt/argon2, when Redmine hashes passwords with salt+SHA1.* A token
is 160 bits of uniform randomness from a CSPRNG; a password is low-entropy and human-chosen. Key
stretching exists to make guessing a low-entropy secret expensive. Brute-forcing 160 bits is not
made infeasible by stretching — it already is. What stretching *would* buy here is nothing, and
what it would cost is a KDF run on every API request, i.e. a denial-of-service surface on the
authentication path. Lookup by digest also has to stay a single indexed query.

**Lookup.** `find_by_value` rejects anything that does not match the format, digests it, and does
one indexed lookup on the unique `hashed_value`. The digest comparison additionally goes through
`ActiveSupport::SecurityUtils.secure_compare`. Note honestly that with a unique index the database
lookup itself is already the comparison, so `secure_compare` here is belt-and-braces, not the thing
that closes a timing channel — it is cheap and it makes the intent explicit for the next reader.

**Expiry** is mandatory (`validates_presence_of :expires_on`) and must be in the future when the
token is created. There is deliberately no "never expires" option: making the safe choice the only
choice is why this feature is worth having over the existing API key.

**The name is unique within its owner** — by validation and by a unique `[user_id, name]` index —
because the name is the only thing a person has to tell one token from another when deciding which
to revoke; two users naming a token the same way is of course fine.

**Revocation is soft.** `revoked_on` is set, the row stays. This is a divergence from the prior art
in the ticket (see below) and it is on purpose: after an incident the question asked is "what did
this credential do and when did we kill it", and a deleted row cannot answer. The row is also what
lets `last_used_on` remain meaningful post-mortem.

**Last used is a table, not a column.** `api_credential_usages` holds one row per credential —
`(credential_kind, credential_id)`, unique by index, plus `last_used_on`. The reason it is not a
column on `personal_access_tokens` is the old API key: *when was this credential last used* is the
same fact for both kinds, and the API key is a row in the shared `tokens` table, which it lives in
together with sessions, autologin, password recovery and feed keys. Giving the API key a
`last_used_on` column means giving one to all of them and writing to that table on every session
check — a much larger blast radius than the feature deserves. One narrow table off to the side
gives both credential kinds the same home, adds nothing to `tokens`, and is the place a third
credential kind would be marked without a new migration. The fact is written through one entry
point, `ApiCredentialUsage.record(kind, id)`: the legacy key is marked in
`User.find_by_api_credential`, from the `Token` row `Token.find_token` has already fetched, so
nothing looks the credential up twice. The price of the separate table is named honestly: one
indexed read of the mark per authenticated request, against a column read that used to come free
with the token row, and a write at most once an hour.

**The mark is throttled** to one write per hour per credential
(`ApiCredentialUsage::LAST_USED_UPDATE_INTERVAL`, which lives there and nowhere else). Without the
throttle, every authenticated GET turns into a write — on a busy integration that is a row-level
write amplification of the entire API. One-hour granularity is enough to answer the only question
the field is for: is this credential still in use, and roughly when did it stop. The token list in
*My account* preloads the marks (`includes(:usage)`), so the page reads them in one query however
many tokens a user owns.

### Audit logging

Every API credential attempt leaves a row in `api_auth_events`: who (`user_id`, null on failure),
what kind of credential (`personal_access_token`, `api_key` or `failed`), which token when it is
known (`personal_access_token_id` — set on failures with an expired or revoked token too, because
"who is still sending the credential we killed" is exactly the post-incident question), the
request path and HTTP method, the remote IP, and when. No secret material is stored, not even a
prefix of the credential: the path is recorded without the query string precisely because `?key=`
is a legal way to pass one.

The hook is a single controller method, `ApplicationController#find_user_by_api_credential`,
wrapping the `User.find_by_api_credential` seam — which is why the audit covers the legacy API
key exactly as it covers personal access tokens, and would cover a third credential kind for
free. It lives in the controller because that is where path, method and IP exist; the model seam
stays a pure lookup returning a plain `User`. Which kind matched is re-derived from the
credential's prefix plus one indexed lookup rather than by widening the seam's return value into
a result object — the extra query only ever runs for token-shaped credentials.

Two edges are deliberate. A successful username/password HTTP Basic login writes nothing: no API
credential was used, the seam is never reached. A *failed* Basic login does write a `failed` row,
because at that point the username has been tried as an API credential and the two cases are
indistinguishable by construction — the row still contains no username and no secret.

The write is synchronous, one insert per authenticated API request, and wrapped so that an audit
DB error fails loud in the log but never turns into a client-facing 500 (`ApiAuthEvent.record`
rescues everything; asserted by test). At the scale where that insert matters, the path out is
buffering — an async insert or an append-only log file — behind the same `ApiAuthEvent.record`
interface. Retention and pruning are deliberately out of scope, same as for Redmine's other
growing tables.

## 4. Prior art, and where this diverges

**This must be said plainly: a patch implementing this same pillar already exists in the ticket**
(comment #11, `personal-access-tokens-43881.patch`, attachment 36640, by Bogdan Egikov). It was read as prior art
after the model here was written, and there is real convergence — the `rmpat_` prefix, digest-only
storage and the one-hour last-used throttle appear in both. Those are the choices the problem
pushes you toward, and pretending otherwise by renaming things would be cosmetics.

Where this branch deliberately differs:

| | prior-art patch | here | why |
|---|---|---|---|
| revocation | `destroy` — row deleted | `revoked_on` — row kept | a deleted credential cannot be investigated |
| expiry precision | `expires_on` is a `date` | `expires_on` is a `datetime` | "expires at end of day in whose timezone" is a question with no good answer on an API credential |
| last used | `last_used_on` column on the token | `api_credential_usages` row, keyed by kind + id | the same fact is needed for the legacy API key, which cannot get a column without one landing on sessions and autologin too (see §3) |
| scope of the patch | PAT + scopes + audit log in one | PAT only | the maintainer (Holger Just, comment #12) asked precisely for the opposite: *"each of the features proposed here are rather large and complex on its own… we should try to separate these features into separate issues"* |

The third row is the important one. That patch was reviewed and the review said: too large, split it.
Submitting the same shape again ignores the feedback that is sitting in the ticket in public.

**The open question the maintainer raised** (comment #12) is whether personal access tokens should
exist at all, or whether long-lived tokens should be issued through the existing OAuth applications
(#24808), which already carry scopes and lifetimes. That is a legitimate objection and this branch
does not pretend to settle it. The argument for a separate model: OAuth applications are a
*three-party* construct — an application, a user, a grant — and the thing a user wants when wiring
a cron job is a *two-party* credential with no application to register. Redmine already
acknowledges that split by keeping the API key alongside OAuth. This replaces the API key, not
OAuth.

## 5. Deliberately not done

- **Rate limiting** — excluded by the brief; it is under active discussion in the ticket, with two
  competing patches already attached to it (`0001-Add-rate-limiting-for-the-REST-API-43881.patch`,
  attachments 36477 and 36483).
- **Scopes.** The mechanism is nearly free to add on top (the permission intersection already
  exists from OAuth) but it is a separate concern and, per the maintainer's own review, belongs in
  a separate patch. Noted here rather than half-built.
- **CORS, an administration panel over all users' tokens** — same reasoning. (Audit logging was
  originally on this list, then implemented after all — see *Audit logging* above. What moved it:
  the `find_by_api_credential` seam turned out to cover both credential kinds with one hook, so
  the feature stopped being PAT-specific and became a property of the whole API auth path.)
- **A known inherited hole, named rather than hidden:** Redmine issue
  [#44271](https://www.redmine.org/issues/44271) — issue attribute updates bypass the OAuth scope
  intersection. It is a defect in the existing OAuth path, and any scope mechanism layered on
  personal access tokens would inherit it. If scopes are added here, that has to be fixed first or
  the scopes are decorative.

## 6. How to run and verify

Requires Ruby 3.3 and the usual Redmine dependencies.

```bash
bundle install
bin/rails db:migrate                 RAILS_ENV=development
bin/rails db:migrate                 RAILS_ENV=test
bin/rails server
```

Tests:

```bash
bin/rails test test/unit/personal_access_token_test.rb
bin/rails test test/unit/api_auth_event_test.rb
bin/rails test test/functional/my_controller_test.rb
bin/rails test test/integration/api_test/authentication_test.rb
bin/rails test                       # full suite
```

**Measured, not asserted.** The full suite was run twice on the same machine — once on a clean
worktree at tag `6.1.2`, once on this branch — so that "nothing was broken" is a comparison rather
than a claim:

```
6.1.2        5492 runs, 24846 assertions, 0 failures, 1 errors, 28 skips
this branch  5538 runs, 24995 assertions, 0 failures, 1 errors, 28 skips
```

The one error is the same on both sides: `GanttsControllerTest#test_gantt_should_export_to_png`
fails with `MiniMagick::Error` because ImageMagick's `convert` is absent from the container this
ran in. It is environmental and pre-existing. At the time of that comparison the branch added
46 runs and 149 assertions and changed nothing else.

The audit-logging commit landed after that comparison, so the full suite was run a third time on
top of it. That run is reported here as it came out, noise included:

```
this branch + audit   5554 runs, 24654 assertions, 1 failures, 111 errors, 28 skips
```

Every one of those 111 errors traces to a single environmental cause: Rails runs the suite in
parallel worker processes, and the shared SQLite test database serialises writes, so workers
collide. 119 of the error blocks carry `SQLite3::BusyException: database is locked` verbatim;
three more are `NoMethodError: undefined method 'persisted?' for nil` inside
`ApiAuthEventTest` — the same lock hitting the audit insert, which by design rescues and returns
`nil` instead of failing an API request; one is the same exception re-raised through a view. The
single failure is locale bleed between parallel workers: a CommonMark formatter test read its
alert labels in Chinese.

Re-running exactly the 13 files that produced anything, serially (`PARALLEL_WORKERS=1`), leaves
nothing behind:

```
480 runs, 1672 assertions, 0 failures, 1 errors, 1 skips     # 0 occurrences of BusyException
```

The one remaining error is again `test_gantt_should_export_to_png` / ImageMagick. So the
authentication and audit code is not implicated in any of it — but the honest form of that
sentence is the numbers above, not a green line.

*On the environment:* there is no Ruby on the host this was developed on and no root to install
one, so everything — bundler, migrations, tests, the server — ran in a `ruby:3.3-bookworm`
container with the source tree bind-mounted. That is also why ImageMagick is missing, and why the
baseline run exists at all: with an unusual environment, "the tests pass" is only worth something
next to "and they passed identically before my patch".

End-to-end, against a running server (enable the REST API first in
*Administration → Settings → API*):

```bash
# create a token in the console
bin/rails runner 'p PersonalAccessToken.create!(user: User.find_by_login("admin"),
                  name: "demo", expires_on: 30.days.from_now).plain_value'

curl -s -o /dev/null -w '%{http_code}\n' -H "X-Redmine-API-Key: $TOKEN" localhost:3000/users/current.json  # 200
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Redmine-API-Key: garbage"  localhost:3000/users/current.json  # 401
curl -s -o /dev/null -w '%{http_code}\n' -u "$TOKEN:x"  localhost:3000/users/current.json                    # 200
```

## 7. Limits of this approach

- A token grants **the user's full permissions**. Until scopes land, a personal access token is
  exactly as powerful as the password, minus the web session. It is an improvement in *blast radius
  over time* (revocable, expiring, per-integration) and not yet in *blast radius per request*.
- The last-used mark is throttled to an hour, so it answers "is this alive", not "when exactly was
  the last call". It is not an audit log and should not be read as one.
- **A `key=` credential is not API-format-only, and that surprised me.** `find_current_user` gates
  the credential branch on `Setting.rest_api_enabled? && accept_api_auth?` — on the *action*, not on
  `api_request?` — so `GET /issues?key=…` authenticates over plain HTML too. That is pre-existing
  Redmine behaviour of the API key, inherited here rather than introduced: the test
  `test_personal_access_token_should_authenticate_like_an_api_key_without_opening_a_session` asserts
  the two credentials return the *same* status on such a request, and pins the property that does
  matter — neither of them opens a session, so the credential authenticates one request and leaves
  no cookie behind. Changing that gate is an API-wide behaviour change and does not belong in this
  patch.
- The digest is unsalted by design (see §3). That means two users holding the *same* token value
  would collide — impossible in practice at 160 bits, and the unique index turns the impossible
  case into a create-time failure rather than a silent cross-user match.
- Expiry is checked at authentication time, not by a sweeper. Expired rows accumulate until
  something prunes them; no pruning job is included.

## 8. How this was built — the AI workflow

I work through an AI agent platform I built and run in production (Imperia OS); the agent is
Claude (Anthropic). On this assignment the agent wrote the code and ran the suites; the decisions
were made in conversation and are visible in the raw logs that accompany this submission: keeping
the scope to the PAT core after reading the maintainer's review, soft revoke instead of delete,
exact expiry time instead of a date, and treating the patch already attached to the ticket as
prior art rather than pretending it is not there.

Tools: Claude agents driving the edits and test runs; Ruby 3.3 in Docker (`ruby:3.3-bookworm`)
for the app and suites against SQLite; git and the GitHub CLI. Every turn is persisted by the
platform, so the logs are exports from its store, not copy-paste from a chat window: the Russian
original of the conversation, a message-for-message English translation, and the agent's full
tool-call trace. The commit history on this branch is the real work history — nothing squashed.
