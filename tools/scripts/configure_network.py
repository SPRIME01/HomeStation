#!/usr/bin/env python3
import argparse, ipaddress, subprocess, re, sys, os, textwrap

def sh(cmd):
    return subprocess.check_output(cmd, shell=True, text=True).strip()

def detect_default_ipv4():
    out = sh("ip -4 route show default || true")
    m = re.search(r"default via (\d+\.\d+\.\d+\.\d+) dev (\S+)(?:.*?src (\d+\.\d+\.\d+\.\d+))?", out)
    if m:
        gw, dev, src = m.group(1), m.group(2), m.group(3) or ""
        if not src:
            try:
                addrs = sh(f"ip -4 -o addr show dev {dev} | awk '{{print $4}}' | cut -d/ -f1 || true").splitlines()
                src = addrs[0] if addrs else ""
            except Exception:
                src = ""
        return {"gw":gw, "dev":dev, "ip":src}
    return {"gw":"", "dev":"", "ip":""}

def choose_pool(cidr, host_ip):
    net = ipaddress.ip_network(cidr, strict=False)
    hosts = list(net.hosts())
    if net.prefixlen == 24 and len(hosts) >= 250:
        start = ipaddress.ip_address(int(net.network_address) + 240)
        end   = ipaddress.ip_address(int(net.network_address) + 250)
    else:
        start = hosts[-11]; end = hosts[-1]
    hip = ipaddress.ip_address(host_ip)
    if start <= hip <= end:
        start = ipaddress.ip_address(int(start) - 16)
        end   = ipaddress.ip_address(int(end) - 16)
    return f"{start}-{end}"

def patch_metallb_pool(file_path, pool):
    import re, pathlib
    p = pathlib.Path(file_path)
    txt = p.read_text()
    new = re.sub(r"addresses:\s*\n\s*-\s*[0-9\.\-]+", f"addresses:\n    - {pool}", txt)
    p.write_text(new)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool-start", default="")
    ap.add_argument("--pool-end", default="")
    ap.add_argument("--cidr", default="")
    ap.add_argument("--file", default="deploy/metallb/ipaddresspool.yaml")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    det = detect_default_ipv4()
    if not det["ip"]:
        print("Could not detect default IPv4; specify --cidr and --pool-* manually.", file=sys.stderr)
        sys.exit(1)

    host_ip = det["ip"]
    cidr = args.cidr or ".".join(host_ip.split(".")[:3]) + ".0/24"
    pool = (args.pool_start and args.pool_end) and f"{args.pool_start}-{args.pool_end}" or choose_pool(cidr, host_ip)
    print(f"Detected host IP: {host_ip}, CIDR: {cidr}, MetalLB pool: {pool}")
    if args.write:
        patch_metallb_pool(args.file, pool)
        print(f"Updated {args.file}")

if __name__ == "__main__":
    main()
