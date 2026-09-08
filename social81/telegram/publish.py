#!/usr/bin/env python3
"""SOCIAL81+ Telegram publisher for @sicurissimoonline.
Uses only stdlib and GitHub Secrets. Supports text or photo+caption publishing.
"""
from __future__ import annotations
import argparse, json, mimetypes, os, sys, uuid
from urllib.request import Request, urlopen

API='https://api.telegram.org/bot{token}/{method}'

def request_json(url, data=None, headers=None):
    req=Request(url,data=data,headers=headers or {},method='POST')
    with urlopen(req,timeout=30) as r:
        payload=json.loads(r.read().decode('utf-8'))
    if not payload.get('ok'):
        raise RuntimeError(str(payload))
    return payload

def form(fields):
    from urllib.parse import urlencode
    return urlencode(fields).encode()

def multipart(fields, file_field, path):
    boundary='----SOCIAL81'+uuid.uuid4().hex
    out=bytearray()
    for k,v in fields.items():
        out += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    ctype=mimetypes.guess_type(path)[0] or 'application/octet-stream'
    name=os.path.basename(path)
    out += f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{name}"\r\nContent-Type: {ctype}\r\n\r\n'.encode()
    out += open(path,'rb').read()
    out += f'\r\n--{boundary}--\r\n'.encode()
    return bytes(out), {'Content-Type':f'multipart/form-data; boundary={boundary}'}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--text',default=os.getenv('SOCIAL81_TELEGRAM_TEXT',''))
    ap.add_argument('--text-file')
    ap.add_argument('--photo',default=os.getenv('SOCIAL81_TELEGRAM_PHOTO'))
    ap.add_argument('--chat-id',default=os.getenv('TELEGRAM_CHAT_ID','@sicurissimoonline'))
    args=ap.parse_args()
    token=os.getenv('TELEGRAM_BOT_TOKEN')
    if not token: raise RuntimeError('Missing TELEGRAM_BOT_TOKEN GitHub secret')
    text=args.text
    if args.text_file: text=open(args.text_file,encoding='utf-8').read().strip()
    if not text: raise RuntimeError('No Telegram text supplied')
    # Telegram photo captions have a lower limit than normal messages.
    if args.photo:
        caption=text[:1000]
        fields={'chat_id':args.chat_id,'caption':caption}
        body,headers=multipart(fields,'photo',args.photo)
        result=request_json(API.format(token=token,method='sendPhoto'),body,headers)
        # Preserve remaining copy as a follow-up message when needed.
        if len(text)>1000:
            request_json(API.format(token=token,method='sendMessage'),form({'chat_id':args.chat_id,'text':text[1000:]}),{'Content-Type':'application/x-www-form-urlencoded'})
    else:
        result=request_json(API.format(token=token,method='sendMessage'),form({'chat_id':args.chat_id,'text':text}),{'Content-Type':'application/x-www-form-urlencoded'})
    msg=result['result']
    print(json.dumps({'ok':True,'chat_id':args.chat_id,'message_id':msg.get('message_id')},ensure_ascii=False))

if __name__=='__main__':
    try: main()
    except Exception as e:
        print(f'Telegram publish failed: {e}',file=sys.stderr); sys.exit(1)
