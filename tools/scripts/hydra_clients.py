#!/usr/bin/env python3
import argparse, json, sys, urllib.request
def http(method, url, data=None):
    req = urllib.request.Request(url, method=method, headers={'Content-Type':'application/json'})
    if data is not None:
        req.data = json.dumps(data).encode()
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode())
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--admin', required=True)
    ap.add_argument('--domain', required=True)
    ap.add_argument('--config', required=True)
    args = ap.parse_args()
    if args.config.endswith(('.yaml','.yml')):
        try:
            import yaml
        except ImportError:
            print("Install pyyaml or convert to JSON.", file=sys.stderr); sys.exit(1)
        cfg = yaml.safe_load(open(args.config))
    else:
        cfg = json.load(open(args.config))
    existing = {c["client_id"]: c for c in http("GET", args.admin + "/clients")}
    for c in cfg.get("clients", []):
        c["redirect_uris"] = [u.replace("homelab.lan", args.domain) for u in c.get("redirect_uris", [])]
        cid = c["client_id"]
        if cid in existing:
            http("PUT", f"{args.admin}/clients/{cid}", c); print("Updated client:", cid)
        else:
            http("POST", f"{args.admin}/clients", c); print("Created client:", cid)
if __name__ == "__main__":
    main()
