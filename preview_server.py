#!/usr/bin/env python3
import http.server, json, socket, ipaddress, urllib.parse, urllib.request, html.parser, re
from pathlib import Path

class Metadata(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(); self.meta={}; self.title=''; self.in_title=False
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag=='meta': self.meta[(a.get('property') or a.get('name') or '').lower()]=a.get('content','')
        if tag=='title': self.in_title=True
    def handle_endtag(self, tag):
        if tag=='title': self.in_title=False
    def handle_data(self, data):
        if self.in_title: self.title+=data

class EmbedText(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(); self.inside=False; self.text=[]
    def handle_starttag(self, tag, attrs):
        if tag=='p': self.inside=True
        if tag=='br' and self.inside: self.text.append(' ')
    def handle_endtag(self, tag):
        if tag=='p': self.inside=False
    def handle_data(self, data):
        if self.inside: self.text.append(data)


def public_url(url):
    u=urllib.parse.urlsplit(url)
    if u.scheme not in ('http','https') or not u.hostname or u.username or u.password: raise ValueError('无效链接')
    for item in socket.getaddrinfo(u.hostname, u.port or (443 if u.scheme=='https' else 80), type=socket.SOCK_STREAM):
        ip=ipaddress.ip_address(item[4][0])
        if ip.is_loopback or ip.is_link_local or ip.is_unspecified or (ip.version==4 and not ip.is_global) or (ip.version==6 and ip in ipaddress.ip_network('fc00::/7')): raise ValueError('仅支持公网链接')
    return url
class Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)
opener=urllib.request.build_opener(Redirect())
def fetch(url):
    req=urllib.request.Request(public_url(url),headers={'User-Agent':'Mozilla/5.0 (compatible; ShiyePreview/1.0)'})
    with opener.open(req, timeout=12) as response:
        return response.read(1_000_000).decode('utf-8','replace')
def extract(url):
    u=urllib.parse.urlsplit(public_url(url)); host=u.hostname.lower()
    result={'title':'','description':'','image':'','author':''}
    if host=='youtu.be' or host.endswith('youtube.com'):
        try:
            d=json.loads(fetch('https://www.youtube.com/oembed?format=json&url='+urllib.parse.quote(url,safe='')))
            result.update(title=d.get('title',''),author=d.get('author_name',''),image=d.get('thumbnail_url',''))
        except Exception: pass
    if host in ('x.com','www.x.com','twitter.com','www.twitter.com','mobile.twitter.com') and re.search(r'/status/\d+',u.path):
        try:
            post_path=re.match(r'^/(?:[^/]+)/status/\d+',u.path)
            canonical='https://x.com'+post_path.group(0) if post_path else url
            d=json.loads(fetch('https://publish.twitter.com/oembed?omit_script=true&url='+urllib.parse.quote(canonical,safe='')))
            parser=EmbedText(); parser.feed(d.get('html',''))
            result['title']=re.sub(r'\s+',' ',''.join(parser.text)).strip()
            result['author']=d.get('author_name','')
        except Exception: pass
    try:
        p=Metadata(); p.feed(fetch(url)); m=p.meta
        result['title']=result['title'] or m.get('og:title') or m.get('twitter:title') or p.title
        description=m.get('og:description') or m.get('twitter:description') or m.get('description') or ''
        if 'enjoy the videos and music you love' not in description.lower(): result['description']=description or result['description']
        result['author']=result['author'] or m.get('author') or m.get('article:author') or m.get('twitter:creator') or ''
        result['image']=result['image'] or m.get('og:image') or m.get('twitter:image') or ''
        result['image']=urllib.parse.urljoin(url,result['image']) if result['image'] else ''
    except Exception: pass
    if not result['title'] and not result['description']: raise ValueError('网站没有返回可读取的公开信息')
    return {k:str(v)[:2000] for k,v in result.items()}
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(Path(__file__).parent/'web'),**kwargs)
    def do_POST(self):
        if self.path!='/api/metadata': self.send_error(404); return
        if self.headers.get('Origin') not in ('http://127.0.0.1:8765','http://localhost:8765'): self.send_error(403); return
        try:
            length=int(self.headers.get('Content-Length','0'))
            if length>8192: raise ValueError('请求过大')
            data=json.loads(self.rfile.read(length)); result=extract(data['url']); code=200
        except Exception as e: result={'error':str(e)}; code=400
        body=json.dumps(result,ensure_ascii=False).encode(); self.send_response(code); self.send_header('Content-Type','application/json; charset=utf-8'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass
if __name__=='__main__':
    print('拾页预览：http://127.0.0.1:8765',flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1',8765),Handler).serve_forever()
