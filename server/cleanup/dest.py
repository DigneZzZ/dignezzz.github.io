import sys
import subprocess
import requests
import time
import threading
import socket
import shutil
import json

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

console = Console()

results = {
    "domain": "",
    "port": None,
    "tls_supported": False,
    "http2_supported": False,
    "cdn_used": False,
    "redirect_found": False,
    "ping": None,
    "rating": 0,
    "cdn_provider": None,
    "cdns": [],
    "negatives": [],
    "positives": [],
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
            console.print(f"[red]Error: failed to install {command_name}. Please install manually.[/red]")
            sys.exit(1)

def check_port_availability(domain, port, timeout=5):
    try:
        with socket.create_connection((domain, port), timeout=timeout):
            return True
    except:
        return False

def check_tls(domain, port, progress, task_id):
    try:
        progress.update(task_id, description="Checking TLS 1.3 support...")
        proc = subprocess.run(
            ["openssl", "s_client", "-connect", f"{domain}:{port}", "-tls1_3"],
            input="",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            text=True,
        )
        output = proc.stdout + proc.stderr
        if proc.returncode == 0 and ("TLSv1.3" in output or "New, TLSv1.3" in output):
            results["tls_supported"] = True
            results["positives"].append("TLS 1.3 supported")
            progress.update(task_id, description="[green]TLS 1.3 supported[/green]", completed=1)
        else:
            proc = subprocess.run(
                ["openssl", "s_client", "-connect", f"{domain}:{port}"],
                input="",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                text=True,
            )
            output = proc.stdout + proc.stderr
            tls_version = None
            for line in output.splitlines():
                if "Protocol  :" in line or "Protocol :" in line:
                    tls_version = line.split(":", 1)[1].strip()
                    break
            if tls_version:
                results["negatives"].append(f"TLS 1.3 not supported (using {tls_version})")
                progress.update(task_id, description=f"[yellow]TLS 1.3 not supported[/yellow] ({tls_version})", completed=1)
            else:
                results["negatives"].append("Could not determine TLS version")
                progress.update(task_id, description="[red]Could not determine TLS version[/red]", completed=1)
    except subprocess.TimeoutExpired:
        results["negatives"].append("Failed to connect for TLS check")
        progress.update(task_id, description="[red]Error during TLS check[/red]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error during TLS check: {e}")
        progress.update(task_id, description="[red]Error during TLS check[/red]", completed=1)

def check_http2(domain, port, progress, task_id):
    try:
        progress.update(task_id, description="Checking HTTP/2 support...")
        proc = subprocess.run(
            ["curl", "-I", "-s", "--http2", f"https://{domain}:{port}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            text=True,
        )
        if "HTTP/2" in proc.stdout or "HTTP/2" in proc.stderr:
            results["http2_supported"] = True
            results["positives"].append("HTTP/2 supported")
            progress.update(task_id, description="[green]HTTP/2 supported[/green]", completed=1)
        else:
            proc = subprocess.run(
                ["curl", "-I", "-s", f"https://{domain}:{port}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                text=True,
            )
            http_version = None
            for line in proc.stdout.splitlines():
                if line.startswith("HTTP/"):
                    http_version = line.split(" ", 1)[0].strip()
                    break
            if http_version:
                results["negatives"].append(f"HTTP/2 not supported (using {http_version})")
                progress.update(task_id, description=f"[yellow]HTTP/2 not supported[/yellow] ({http_version})", completed=1)
            else:
                results["negatives"].append("Could not determine HTTP version")
                progress.update(task_id, description="[red]Could not determine HTTP version[/red]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error during HTTP/2 check: {e}")
        progress.update(task_id, description="[red]Error during HTTP/2 check[/red]", completed=1)

def check_cdn(domain, port, progress, task_id):
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
    cdn_detected = False
    try:
        progress.update(task_id, description="Checking for CDN...")
        response = requests.head(f"https://{domain}:{port}", timeout=5)
        headers = response.headers
        header_str = str(headers).lower()
        for key, provider in cdn_providers.items():
            if key in header_str:
                results["cdn_used"] = True
                results["cdn_provider"] = provider
                results["cdns"].append(provider)
                cdn_detected = True
                break
        if not cdn_detected:
            results["positives"].append("CDN not used")
            progress.update(task_id, description="[green]CDN not used[/green]", completed=1)
        else:
            results["negatives"].append(f"CDN used: {provider}")
            progress.update(task_id, description=f"[yellow]CDN used[/yellow] ({provider})", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error during CDN check: {e}")
        progress.update(task_id, description="[red]Error during CDN check[/red]", completed=1)

def check_redirect(domain, port, progress, task_id):
    try:
        progress.update(task_id, description="Checking for redirects...")
        response = requests.get(f"https://{domain}:{port}", timeout=5, allow_redirects=False)
        if 300 <= response.status_code < 400:
            results["redirect_found"] = True
            results["negatives"].append(f"Redirect found: {response.headers.get('Location')}")
            progress.update(task_id, description="[yellow]Redirect found[/yellow]", completed=1)
        else:
            results["positives"].append("No redirects found")
            progress.update(task_id, description="[green]No redirects found[/green]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error during redirect check: {e}")
        progress.update(task_id, description="[red]Error during redirect check[/red]", completed=1)

def calculate_ping(domain, progress, task_id):
    try:
        progress.update(task_id, description="Calculating ping...")
        proc = subprocess.run(
            ["ping", "-c", "5", domain],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            text=True,
        )
        if proc.returncode == 0:
            for line in proc.stdout.split("\n"):
                if "rtt min/avg/max/mdev" in line:
                    avg_ping = line.split("/")[4]
                    results["ping"] = float(avg_ping)
                    break
            if results["ping"] is not None:
                if results["ping"] <= 2:
                    results["rating"] = 5
                elif results["ping"] <= 3:
                    results["rating"] = 4
                elif results["ping"] <= 5:
                    results["rating"] = 3
                elif results["ping"] <= 8:
                    results["rating"] = 2
                else:
                    results["rating"] = 1
                if results["rating"] >= 4:
                    results["positives"].append(f"Average ping: {results['ping']} ms (Rating: {results['rating']}/5)")
                else:
                    results["negatives"].append(f"High ping: {results['ping']} ms (Rating: {results['rating']}/5)")
                progress.update(task_id, description=f"Ping calculation... [green]{results['ping']} ms[/green]", completed=1)
            else:
                results["negatives"].append("Could not determine average ping")
                progress.update(task_id, description="[red]Could not determine average ping[/red]", completed=1)
        else:
            results["negatives"].append("Failed to ping the host")
            progress.update(task_id, description="[red]Failed to ping host[/red]", completed=1)
    except Exception as e:
        results["negatives"].append(f"Error during ping calculation: {e}")
        progress.update(task_id, description="[red]Error during ping calculation[/red]", completed=1)

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
        positives.append("CDN not used")

    if not results["redirect_found"]:
        positives.append("No redirects found")
    else:
        reasons.append("Redirect found")

    if results["ping"] is not None:
        if results["rating"] >= 4:
            positives.append(f"Average ping: {results['ping']} ms (Rating: {results['rating']}/5)")
        else:
            reasons.append(f"High ping: {results['ping']} ms (Rating: {results['rating']}/5)")
    else:
        reasons.append("Could not determine average ping")

    acceptable = False
    if results.get("rating", 0) >= 4:
        if not reasons:
            acceptable = True
        elif len(reasons) == 1 and "CDN used" in reasons[0]:
            acceptable = True
        else:
            acceptable = False
    else:
        acceptable = False

    if acceptable:
        console.print("[bold green]Site is suitable for DEST for Reality for the following reasons:[/bold green]")
        for positive in positives:
            console.print(f"[green]- {positive}[/green]")
    else:
        console.print("[bold red]Site is NOT suitable for DEST for Reality for the following reasons:[/bold red]")
        for reason in reasons:
            console.print(f"[yellow]- {reason}[/yellow]")
        if positives:
            console.print("\n[bold green]Positive points:[/bold green]")
            for positive in positives:
                console.print(f"[green]- {positive}[/green]")

    port_display = results['port'] if results['port'] else '443/80'
    if acceptable:
        console.print(f"\n[bold green]Host {results['domain']}:{port_display} is suitable as dest[/bold green]")
    else:
        console.print(f"\n[bold red]Host {results['domain']}:{port_display} is NOT suitable as dest[/bold red]")

def main(domain_input):
    if ':' in domain_input:
        domain, port = domain_input.split(':', 1)
        port = int(port)
    else:
        domain = domain_input
        port = None

    results["domain"] = domain
    results["port"] = port

    check_and_install_command("openssl")
    check_and_install_command("curl")
    check_and_install_command("dig")
    check_and_install_command("whois")

    console.print(f"\n[bold cyan]Checking host:[/bold cyan] {domain}")
    if port:
        console.print(f"[bold cyan]Port:[/bold cyan] {port}")
        ports_to_check = [port]
    else:
        console.print(f"[bold cyan]Default ports:[/bold cyan] 443, 80")
        ports_to_check = [443, 80]

    for port in ports_to_check:
        if check_port_availability(domain, port):
            results["port"] = port
            console.print(f"[green]Port {port} available. Proceeding with check...[/green]")
            break
        else:
            console.print(f"[yellow]Port {port} unavailable. Trying next port...[/yellow]")
    else:
        console.print(f"[red]Host {domain} unavailable on ports {', '.join(map(str, ports_to_check))}[/red]")
        sys.exit(1)

    with Progress(
        SpinnerColumn(finished_text=""),
        TextColumn("{task.description}"),
    ) as progress:
        tasks = {}
        tasks['tls'] = progress.add_task("Checking TLS 1.3 support...", total=1)
        tasks['http2'] = progress.add_task("Checking HTTP/2 support...", total=1)
        tasks['cdn'] = progress.add_task("Checking for CDN...", total=1)
        tasks['redirect'] = progress.add_task("Checking for redirects...", total=1)
        tasks['ping'] = progress.add_task("Calculating ping...", total=1)

        threads = []

        t_tls = threading.Thread(target=check_tls, args=(domain, port, progress, tasks['tls']))
        t_http2 = threading.Thread(target=check_http2, args=(domain, port, progress, tasks['http2']))
        t_cdn = threading.Thread(target=check_cdn, args=(domain, port, progress, tasks['cdn']))
        t_redirect = threading.Thread(target=check_redirect, args=(domain, port, progress, tasks['redirect']))
        t_ping = threading.Thread(target=calculate_ping, args=(domain, progress, tasks['ping']))

        threads.extend([t_tls, t_http2, t_cdn, t_redirect, t_ping])

        for t in threads:
            t.start()
            time.sleep(0.1)

        for t in threads:
            t.join()

    display_results()

if __name__ == "__main__":
    if len(sys.argv) != 2:
        console.print("[bold red]Usage: script.py <domain[:port]>[/bold red]")
        sys.exit(1)
    domain_input = sys.argv[1]
    main(domain_input)
