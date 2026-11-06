(() => {
  let pairing;
  try { pairing = validatePairing(location.href); } catch { return; }
  const button = document.createElement('button');
  button.id = 'shiori-connect';
  button.textContent = '通过 Shiori Bridge 连接 Pixiv';
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const api = globalThis.browser ?? globalThis.chrome;
      const response = await api.runtime.sendMessage({kind: 'pair', url: location.href});
      if (!response?.ok) throw new Error(response?.error ?? '扩展未响应');
      button.textContent = '请在扩展确认页继续';
    } catch (e) { button.textContent = e.message; button.disabled = false; }
  });
  document.body.append(button);
})();
