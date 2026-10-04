(function () {
  function placeMailPreference() {
    const preference = document.getElementById('redmine-slack-mail-preference');
    const noSelfNotified = document.getElementById('pref_no_self_notified');
    const anchor = noSelfNotified && noSelfNotified.closest('p');
    if (preference && anchor && preference.closest('form') === anchor.closest('form')) {
      anchor.insertAdjacentElement('afterend', preference);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', placeMailPreference, { once: true });
  } else {
    placeMailPreference();
  }
})();
