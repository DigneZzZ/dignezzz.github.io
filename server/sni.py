import sys
import subprocess
import threading
import time
import socket
import json
import shutil

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.table import Table

console = Console()

results = {
    "domain": "",
    "tls_supported": False,
    "http2_supported": False,
    "http3_supported": False,
    "cdn_used": False,
    "redirect_found": False,
    "negatives": [],
    "positives": [],
    "cdns": [],
}

def check_and_install_command(command_name):
    if shutil.which(command_name) is None:
        console.print(f"[yellow]Utility {command_name} not found. Installing...[/yellow]")
        proc = subprocess.run(
            ["sudo", "apt-get", "install", "-y", command_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if shutil.which(command_name) is None:
            console.print(f"[red]Error: Failed to install {command_name}. Please install it manually.[/red]")
            sys.exit(1)

def check_tls(domain, progress, task_id):
    try:
        progress.update(task_id, description="Checking TLS 1.3 support...")
        proc = subprocess.run(
            ["openssl", "s_client", "-connect", f"{domain}:443", "-tls1_3"],
            input="",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            text=True,
        )
        output = proc.stdout + proc.stderr
        if "TLSv1.3" in output:
            results["tls_supported"] = True
            results["positives"].append("TLS 1.3 supported")
            progress.update(task_id, description="[green]TLS 1.3 supported[/green]", completed=1)
        else:
            proc = subprocess.run(
                ["openssl", "s_client", "-connect", f"{domain}:443"],
                input="",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                text=True,
            )
            output = proc.stdout + proc.stderr
            for line in output.splitlines():
                if "Protocol  :" in line or "Protocol :" in line:
                    tls_version = line.split(":", 1)[1].strip()
                    results["negatives"].append(f"TLS 1.3 not supported. Used version: {tls_version}")
                    progress.update(task_id, description=f"[yellow]TLS 1.3 not supported[/yellow] ({tls_version})", completed=1)
                    break
            else:
                results["negatives"].append("Failed to determine used TLS version")
                progress.update(task_id, description="[red]Failed to determine TLS version[/red]", completed=1)
    except subprocess.TimeoutExpired:
        results["negatives"].append("Failed to connect to check TLS")
        progress.update(task_id, description="[red]Error checking TLS[/red]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error checking TLS: {e}")
        progress.update(task_id, description="[red]Error checking TLS[/red]", completed=1)

def check_http_versions(domain, progress, task_ids):
    http2_task_id, http3_task_id = task_ids

    try:
        progress.update(http2_task_id, description="Checking HTTP/2 support...")
        proc = subprocess.run(
            ["curl", "-I", "-s", "--max-time", "5", "--http2", f"https://{domain}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if "HTTP/2" in proc.stdout:
            results["http2_supported"] = True
            results["positives"].append("HTTP/2 supported")
            progress.update(http2_task_id, description="[green]HTTP/2 supported[/green]", completed=1)
        else:
            proc = subprocess.run(
                ["openssl", "s_client", "-alpn", "h2", "-connect", f"{domain}:443"],
                input="",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                text=True,
            )
            if "ALPN protocol: h2" in proc.stdout:
                results["http2_supported"] = True
                results["positives"].append("HTTP/2 supported")
                progress.update(http2_task_id, description="[green]HTTP/2 supported[/green]", completed=1)
            else:
                results["negatives"].append("HTTP/2 not supported")
                progress.update(http2_task_id, description="[yellow]HTTP/2 not supported[/yellow]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error checking HTTP/2: {e}")
        progress.update(http2_task_id, description="[red]Error checking HTTP/2[/red]", completed=1)

    try:
        progress.update(http3_task_id, description="Checking HTTP/3 support...")
        proc = subprocess.run(
            ["openssl", "s_client", "-alpn", "h3", "-connect", f"{domain}:443"],
            input="",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            text=True,
        )
        if "ALPN protocol: h3" in proc.stdout or "ALPN protocol: h3" in proc.stderr:
            results["http3_supported"] = True
            results["positives"].append("HTTP/3 supported")
            progress.update(http3_task_id, description="[green]HTTP/3 supported[/green]", completed=1)
        else:
            results["negatives"].append("HTTP/3 not supported or unable to determine")
            progress.update(http3_task_id, description="[yellow]HTTP/3 not supported[/yellow]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error checking HTTP/3: {e}")
        progress.update(http3_task_id, description="[red]Error checking HTTP/3[/red]", completed=1)

def check_redirect(domain, progress, task_id):
    try:
        progress.update(task_id, description="Checking for redirects...")
        proc = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{redirect_url}", "--max-time", "5", f"https://{domain}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        redirect_url = proc.stdout.strip()
        if redirect_url:
            results["redirect_found"] = True
            results["negatives"].append(f"Redirect found: {redirect_url}")
            progress.update(task_id, description=f"[yellow]Redirect found[/yellow]: {redirect_url}", completed=1)
        else:
            results["positives"].append("No redirect")
            progress.update(task_id, description="[green]No redirect[/green]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error checking redirect: {e}")
        progress.update(task_id, description="[red]Error checking redirect[/red]", completed=1)

def check_cdn(domain, progress, task_id):
    cdn_detected = False
    cdn_providers = {
        "cloudflare": "Cloudflare",
        "akamai": "Akamai",
        "fastly": "Fastly",
        "incapsula": "Imperva Incapsula",
        "sucuri": "Sucuri",
        "stackpath": "StackPath",
        "cdn77": "CDN77",
        "edgecast": "Verizon Edgecast",
        "keycdn": "KeyCDN",
        "azure": "Microsoft Azure CDN",
        "aliyun": "Alibaba Cloud CDN",
        "baidu": "Baidu Cloud CDN",
        "tencent": "Tencent Cloud CDN",
    }

    try:
        progress.update(task_id, description="Analyzing HTTP headers for CDN detection...")
        proc = subprocess.run(
            ["curl", "-s", "-I", "--max-time", "5", f"https://{domain}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        headers = proc.stdout.lower()
        for key, provider in cdn_providers.items():
            if key in headers:
                results["cdn_used"] = True
                results["cdns"].append(f"{provider} (via headers)")
                cdn_detected = True
                break

        if not cdn_detected:
            progress.update(task_id, description="Checking ASN for CDN detection...")
            proc = subprocess.run(
                ["dig", "+short", domain],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ip = proc.stdout.strip().split('\n')[0]
            if ip:
                proc = subprocess.run(
                    ["whois", "-h", "whois.cymru.com", f" -v {ip}"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                asn_info = proc.stdout.strip().split('\n')[-1]
                owner = ' '.join(asn_info.split()[4:])
                for key, provider in cdn_providers.items():
                    if key in owner.lower():
                        results["cdn_used"] = True
                        results["cdns"].append(f"{provider} (via ASN)")
                        cdn_detected = True
                        break

        if not cdn_detected:
            progress.update(task_id, description="Using ipinfo.io to detect CDN...")
            if shutil.which("jq") is None:
                check_and_install_command("jq")
            proc = subprocess.run(
                ["dig", "+short", domain],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ip = proc.stdout.strip().split('\n')[0]
            if ip:
                proc = subprocess.run(
                    ["curl", "-s", f"https://ipinfo.io/{ip}/json"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                json_output = proc.stdout
                data = json.loads(json_output)
                org = data.get("org", "")
                for key, provider in cdn_providers.items():
                    if key in org.lower():
                        results["cdn_used"] = True
                        results["cdns"].append(f"{provider} (via ipinfo.io)")
                        cdn_detected = True
                        break

        if not cdn_detected:
            progress.update(task_id, description="Analyzing SSL certificate to detect CDN...")
            proc = subprocess.run(
                ["openssl", "s_client", "-connect", f"{domain}:443"],
                input="",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                text=True,
            )
            cert_info = proc.stdout + proc.stderr
            for key, provider in cdn_providers.items():
                if key in cert_info.lower():
                    results["cdn_used"] = True
                    results["cdns"].append(f"{provider} (via SSL certificate)")
                    cdn_detected = True
                    break

        if results["cdn_used"]:
            cdn_list = ', '.join(results["cdns"])
            results["negatives"].append(f"CDN used: {cdn_list}")
            progress.update(task_id, description=f"[yellow]CDN used[/yellow]: {cdn_list}", completed=1)
        else:
            results["positives"].append("No CDN used")
            progress.update(task_id, description="[green]No CDN used[/green]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error checking CDN: {e}")
        progress.update(task_id, description="[red]Error checking CDN[/red]", completed=1)

def display_results():
    console.print("\n[bold cyan]===== Check Results =====[/bold cyan]\n")
    reasons = []
    positives = []

    if results["tls_supported"]:
        positives.append("TLS 1.3 supported")
    else:
        reasons.append("TLS 1.3 not supported")

    if results["http2_supported"]:
        positives.append("HTTP/2 supported")
    else:
        reasons.append("HTTP/2 not supported")

    if results["cdn_used"]:
        cdn_list = ', '.join(results["cdns"])
        reasons.append(f"CDN used: {cdn_list}")
    else:
        positives.append("No CDN used")

    if not results["redirect_found"]:
        positives.append("No redirect")
    else:
        reasons.append("Redirect found")

    if not reasons:
        console.print("[bold green]Site is suitable as SNI for Reality for the following reasons:[/bold green]")
        for positive in positives:
            console.print(f"[green]- {positive}[/green]")
    else:
        console.print("[bold red]Site is not suitable as SNI for Reality for the following reasons:[/bold red]")
        for reason in reasons:
            console.print(f"[yellow]- {reason}[/yellow]")
        if positives:
            console.print("\n[bold green]Positive aspects:[/bold green]")
            for positive in positives:
                console.print(f"[green]- {positive}[/green]")

def main():
    if len(sys.argv) != 2:
        console.print("[bold red]Usage: script.py <domain>[/bold red]")
        sys.exit(1)

    domain = sys.argv[1]
    results["domain"] = domain

    check_and_install_command("openssl")
    check_and_install_command("curl")
    check_and_install_command("dig")
    check_and_install_command("whois")

    console.print(f"\n[bold cyan]Checking domain:[/bold cyan] {domain}")

    with Progress(
        SpinnerColumn(finished_text=""),
        TextColumn("{task.description}"),
    ) as progress:
        tasks = {}
        tasks['tls'] = progress.add_task("Checking TLS 1.3 support...", total=1)
        tasks['http2'] = progress.add_task("Checking HTTP/2 support...", total=1)
        tasks['http3'] = progress.add_task("Checking HTTP/3 support...", total=1)
        tasks['redirect'] = progress.add_task("Checking for redirects...", total=1)
        tasks['cdn'] = progress.add_task("Checking CDN usage...", total=1)

        threads = []

        t_tls = threading.Thread(target=check_tls, args=(domain, progress, tasks['tls']))
        t_http_versions = threading.Thread(target=check_http_versions, args=(domain, progress, (tasks['http2'], tasks['http3'])))
        t_redirect = threading.Thread(target=check_redirect, args=(domain, progress, tasks['redirect']))
        t_cdn = threading.Thread(target=check_cdn, args=(domain, progress, tasks['cdn']))

        threads.extend([t_tls, t_http_versions, t_redirect, t_cdn])

        for t in threads:
            t.start()
            time.sleep(0.1)

        for t in threads:
            t.join()

    display_results()

if __name__ == "__main__":
    main()
