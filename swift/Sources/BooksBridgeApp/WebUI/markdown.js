/* Local-only rendering: no remote images, HTML execution or unsafe URL schemes. */
function renderMarkdown(node, text) {
  const html = marked.parse(String(text), { gfm: true, breaks: false });
  node.innerHTML = DOMPurify.sanitize(html, {
    ALLOWED_TAGS: ['p','br','strong','em','del','h1','h2','h3','h4','h5','h6','blockquote','ul','ol','li','pre','code','hr','table','thead','tbody','tr','th','td','a'],
    ALLOWED_ATTR: ['href','title','start'],
    ALLOW_DATA_ATTR: false
  });
  for (const link of node.querySelectorAll('a')) {
    if (!/^https?:\/\//i.test(link.getAttribute('href') || '')) link.removeAttribute('href');
    link.setAttribute('rel', 'noopener noreferrer');
    link.setAttribute('target', '_blank');
  }
}
