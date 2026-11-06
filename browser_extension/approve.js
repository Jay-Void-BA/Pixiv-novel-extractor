const statusNode = document.querySelector('#status');
const api = globalThis.browser ?? globalThis.chrome;
try {
  const source = decodeURIComponent(location.hash.slice(1));
  const pairing = validatePairing(source);
  document.querySelector('#destination').textContent = pairing.endpoint;
  for (const kind of ['login', 'connect']) {
    document.querySelector(`#${kind}`).addEventListener('click', async (e) => {
      e.target.disabled = true;
      try {
        const result = await api.runtime.sendMessage({kind});
        if (!result?.ok) throw new Error(result?.error ?? '连接失败');
        statusNode.textContent = result.waiting ? '已打开 Pixiv 登录页面，等待登录完成…' : '会话已发送到本机 Shiori。现在可以关闭此页。';
      } catch (error) { statusNode.textContent = error.message; }
      finally { e.target.disabled = false; }
    });
  }
} catch (e) {
  statusNode.textContent = e.message;
  document.querySelectorAll('button').forEach((b) => { b.disabled = true; });
}
