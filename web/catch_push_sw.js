self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    data = {};
  }

  const title = data.title || 'Catch';
  const options = {
    body: data.body || '通知があります',
    tag: data.tag || 'catch-reminder',
    renotify: true,
    data: {
      url: data.url || './',
    },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const target = event.notification.data?.url || './';
  const targetUrl = new URL(target, self.location.origin + self.registration.scope).href;

  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((clients) => {
        for (const client of clients) {
          if (client.url.startsWith(self.location.origin) && 'focus' in client) {
            client.navigate(targetUrl);
            return client.focus();
          }
        }
        return self.clients.openWindow(targetUrl);
      }),
  );
});
