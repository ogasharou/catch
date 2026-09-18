CREATE TABLE IF NOT EXISTS subscriptions (
  device_id TEXT PRIMARY KEY,
  subscription_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS reminders (
  device_id TEXT NOT NULL,
  reminder_id TEXT NOT NULL,
  notify_at TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  url TEXT NOT NULL DEFAULT './',
  tag TEXT NOT NULL DEFAULT 'catch-reminder',
  sent INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, reminder_id)
);

CREATE INDEX IF NOT EXISTS idx_reminders_due
ON reminders(sent, notify_at);
