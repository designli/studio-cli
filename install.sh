#!/usr/bin/env bash
# Public bootstrap only. Studio source and releases require employee sign-in.
set -euo pipefail

studio_install() {
  local studio_url='' studio_tmp studio_node studio_os studio_arch studio_archive studio_version studio_sum studio_runtime
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) [ "$#" -ge 2 ] || { echo 'Missing Studio URL.' >&2; return 1; }; studio_url="$2"; shift 2 ;;
      --help|-h) echo 'Usage: curl -fsSL https://raw.githubusercontent.com/designli/studio-cli/main/install.sh | bash -s -- --url https://your-studio'; return ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$studio_url" ] || { echo 'Add --url https://your-studio to the install command.' >&2; return 1; }
  case "$studio_url" in https://*|http://localhost:*|http://127.0.0.1:*) ;; *) echo 'Use an HTTPS Studio URL.' >&2; return 1 ;; esac
  command -v curl >/dev/null || { echo 'Install curl, then run this command again.' >&2; return 1; }
  umask 077
  studio_tmp="$(mktemp -d)"
  STUDIO_BOOTSTRAP_TMP="$studio_tmp"
  trap 'rm -rf -- "$STUDIO_BOOTSTRAP_TMP"' EXIT
  studio_node="$(command -v node || true)"
  if [ -z "$studio_node" ] || ! "$studio_node" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)' 2>/dev/null; then
    case "$(uname -s)" in Darwin) studio_os=darwin ;; Linux) studio_os=linux ;; *) echo 'Use Terminal on macOS, Linux, or Windows Subsystem for Linux (WSL).' >&2; return 1 ;; esac
    case "$(uname -m)" in x86_64|amd64) studio_arch=x64 ;; arm64|aarch64) studio_arch=arm64 ;; *) echo 'Automatic setup supports Intel/AMD 64-bit and ARM64. Install Node.js 24+, then retry.' >&2; return 1 ;; esac
    echo 'Installing a private Node.js runtime (no administrator password needed)…'
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 'https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt' -o "$studio_tmp/checksums"
    studio_archive="$(awk -v suffix="-$studio_os-$studio_arch.tar.gz" '$2 ~ /^node-v24\.[0-9]+\.[0-9]+-/ && substr($2,length($2)-length(suffix)+1)==suffix {print $2}' "$studio_tmp/checksums")"
    [[ "$studio_archive" =~ ^node-v24\.[0-9]+\.[0-9]+-(darwin|linux)-(x64|arm64)\.tar\.gz$ ]] || { echo 'Could not identify the official Node.js download.' >&2; return 1; }
    studio_version="${studio_archive#node-}"; studio_version="${studio_version%-$studio_os-$studio_arch.tar.gz}"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://nodejs.org/dist/$studio_version/$studio_archive" -o "$studio_tmp/node.tar.gz"
    studio_sum="$(awk -v archive="$studio_archive" '$2==archive {print $1}' "$studio_tmp/checksums")"
    if command -v sha256sum >/dev/null; then
      [ "$(sha256sum "$studio_tmp/node.tar.gz" | awk '{print $1}')" = "$studio_sum" ]
    else
      [ "$(shasum -a 256 "$studio_tmp/node.tar.gz" | awk '{print $1}')" = "$studio_sum" ]
    fi || { echo 'Node.js checksum did not match. Nothing installed.' >&2; return 1; }
    studio_runtime="${STUDIO_CLI_INSTALL_ROOT:-$HOME/.local/share/designli-studio/cli}/runtime/$studio_version-$studio_os-$studio_arch"
    [ ! -L "$studio_runtime" ] || { echo 'The runtime directory must not be a symbolic link.' >&2; return 1; }
    mkdir -p "$studio_runtime"
    tar -xzf "$studio_tmp/node.tar.gz" -C "$studio_runtime" --strip-components=1
    studio_node="$studio_runtime/bin/node"
  fi
  export PATH="$(dirname "$studio_node"):$PATH"
  cat > "$studio_tmp/bootstrap.mjs" <<'STUDIO_BOOTSTRAP'
import {createHash} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {mkdirSync,mkdtempSync,readFileSync,writeFileSync,renameSync,rmSync,lstatSync,chmodSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {homedir,tmpdir} from 'node:os';
import {spawn,spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

const quote=value=>"'"+value.replaceAll("'","'\\''")+"'";
const clean=value=>String(value).replace(/[\x00-\x1f\x7f-\x9f]/g,' ');
const digest=value=>createHash('sha256').update(value).digest('hex');
function privateDirectory(path){mkdirSync(path,{recursive:true,mode:0o700});if(lstatSync(path).isSymbolicLink()||!lstatSync(path).isDirectory())throw Error('Use a private regular installation directory.');}
function atomicJson(path,value){privateDirectory(dirname(path));if(exists(path)&&lstatSync(path).isSymbolicLink())throw Error('Configuration must not be a symbolic link.');const temp=path+'.'+process.pid+'.tmp';try{writeFileSync(temp,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});renameSync(temp,path);chmodSync(path,0o600);}finally{rmSync(temp,{force:true});}}
function exists(path){try{lstatSync(path);return true;}catch(error){if(error.code==='ENOENT')return false;throw error;}}
function readConfig(path){try{return JSON.parse(readFileSync(path,'utf8'));}catch(error){if(error.code==='ENOENT')return {connections:{}};throw Error('Your saved Studio configuration could not be read. It was not changed.');}}
const url=new URL(process.argv[2]);
if((url.protocol!=='https:'&&!(url.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname)))||url.username||url.password||url.pathname!=='/'||url.search||url.hash)throw Error('Use the central Studio HTTPS address, without a project path, query, or credentials.');
const origin=url.origin;
const root=process.env.STUDIO_CLI_INSTALL_ROOT||join(homedir(),'.local/share/designli-studio/cli');
const configPath=process.env.STUDIO_CONFIG||join(homedir(),'.config/designli-studio/connections.json');
const config=readConfig(configPath);
let connection=config.connections?.[origin],freshToken=false;
async function request(path,{body,token=connection?.token,binary=false}={}){
  const response=await fetch(origin+'/api'+path,{method:body?'POST':'GET',redirect:'error',signal:AbortSignal.timeout(60000),headers:{...(body?{'Content-Type':'application/json'}:{}),...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});
  if(!response.ok){const data=await response.json().catch(()=>({}));throw Object.assign(Error(clean(data.error?.message||data.error||'Studio returned '+response.status)),{status:response.status});}
  return binary?response:response.json();
}
async function signIn(){
  if(connection?.token){try{const status=await request('/auth/status');if(status.user&&status.user.role!=='client'){console.log('Using your existing Studio sign-in.');return;}}catch(error){if(error.status!==401)throw error;}}
  connection=undefined;
  const device=await request('/auth/device',{body:{}});
  const verify=new URL(device.verificationUrl);
  if(verify.origin!==origin||!['/','/team/workspace/setup'].includes(verify.pathname)||!/^[A-F0-9]{8}$/.test(device.userCode)||typeof device.deviceCode!=='string'||device.deviceCode.length<20||!Number.isFinite(device.expiresIn)||device.expiresIn<=0||device.expiresIn>900)throw Error('Studio returned an invalid sign-in request.');
  console.log('\nOpen '+verify.href+'\n\nEnter this code from your terminal: '+device.userCode+'\nApprove the connection with your employee account.\n');
  const command=process.platform==='darwin'?'open':process.env.WSL_DISTRO_NAME?'wslview':'xdg-open';
  if(process.env.BROWSER!=='none'){const child=spawn(command,[verify.href],{stdio:'ignore'});child.on('error',()=>{});child.unref();}
  const deadline=Date.now()+device.expiresIn*1000;
  while(Date.now()<deadline){
    await new Promise(resolve=>setTimeout(resolve,4000));
    const result=await request('/auth/device/token',{body:{deviceCode:device.deviceCode},token:undefined});
    if(result.pending)continue;
    if(result.user?.role==='client'||typeof result.token!=='string'||!result.workspaceId)throw Error('Sign in with an employee account to install Studio.');
    connection={token:result.token,expires:result.expires,workspaceId:result.workspaceId};freshToken=true;return;
  }
  throw Error('Sign-in expired. Run the install command again.');
}
let scratch;
try{
  await signIn();
  console.log('Downloading your Studio CLI…');
  const release=await request('/cli-release');
  const artifact=release.artifact;
  if(!/^[a-f0-9]{64}$/.test(release.release)||!artifact||artifact.path!=='/cli-release/artifact'||!Number.isSafeInteger(artifact.size)||artifact.size<=0||artifact.size>80*1024*1024||!/^[a-f0-9]{64}$/.test(artifact.sha256))throw Error('This Studio release has no installable CLI. Ask your administrator to rebuild it.');
  const bytes=Buffer.from(await (await request(artifact.path,{binary:true})).arrayBuffer());
  if(bytes.length!==artifact.size||digest(bytes)!==artifact.sha256)throw Error('CLI download checksum did not match. Nothing installed.');
  const payload=JSON.parse(gunzipSync(bytes,{maxOutputLength:160*1024*1024}));
  if(payload.release!==release.release||!Array.isArray(payload.files))throw Error('CLI release did not match. Nothing installed.');
  const updaters=payload.files.filter(file=>file.path==='cli/update.mjs');
  if(updaters.length!==1)throw Error('CLI installer is missing from this release.');
  const updater=Buffer.from(updaters[0].bytes,'base64');
  if(digest(updater)!==updaters[0].sha256)throw Error('CLI installer checksum did not match.');
  scratch=mkdtempSync(join(tmpdir(),'studio-install-'));chmodSync(scratch,0o700);
  writeFileSync(join(scratch,'update.mjs'),updater,{mode:0o600});
  const {installCliRelease}=await import(pathToFileURL(join(scratch,'update.mjs')).href);
  const installed=await installCliRelease({requiredRelease:release.release,artifact},async()=>new Response(bytes),{root,origin});
  // Older server releases use an env-node launcher. Keep those usable too.
  const loader=join(root,'bin','studio-launcher.mjs');
  writeFileSync(loader,"import {readFileSync} from 'node:fs';import {spawnSync} from 'node:child_process';const p=JSON.parse(readFileSync(new URL('../current.json',import.meta.url),'utf8'));const r=spawnSync(process.execPath,[p.entry,...process.argv.slice(2)],{cwd:process.cwd(),env:process.env,stdio:'inherit'});process.exit(r.status??1);\n",{mode:0o600});
  writeFileSync(installed.launcher,'#!/bin/sh\nexec '+quote(process.execPath)+' '+quote(loader)+' "$@"\n',{mode:0o700});chmodSync(installed.launcher,0o700);
  const employee=join(root,'employee');privateDirectory(employee);
  const bindingPath=join(employee,'.studio.json');
  if(exists(bindingPath)){const binding=JSON.parse(readFileSync(bindingPath,'utf8'));if(binding.origin!==origin||binding.workspaceId!==connection.workspaceId)throw Error('The employee folder is already bound to another Studio. Existing bindings were preserved.');}
  else atomicJson(bindingPath,{origin,workspaceId:connection.workspaceId});
  const bin=join(root,'bin'),pathLine='export PATH='+quote(bin)+':"$PATH"';
  // Verify with a temporary config before saving the employee's connection.
  const probeConfig=join(scratch,'connections.json');atomicJson(probeConfig,{connections:{[origin]:connection}});
  const check=spawnSync(process.execPath,[installed.entry,'cli-version'],{cwd:employee,env:{...process.env,STUDIO_CONFIG:probeConfig},encoding:'utf8'});
  let status;try{status=JSON.parse(check.stdout);}catch{}
  if(check.status!==0||status?.status!=='Current')throw Error('Installed, but the connection check failed. Run the install command again.');
  // Merge at the last moment, preserving other projects and newer connections.
  const latest=readConfig(configPath);latest.connections={...latest.connections,[origin]:connection};delete latest.active;atomicJson(configPath,latest);freshToken=false;
  const shell=(process.env.SHELL||'').split('/').pop();
  const profile=shell==='zsh'?join(process.env.ZDOTDIR||homedir(),'.zshrc'):shell==='bash'?(process.platform==='darwin'?join(homedir(),'.bash_profile'):join(homedir(),'.bashrc')):null;
  if(profile){try{let text='';try{text=readFileSync(profile,'utf8');}catch(error){if(error.code!=='ENOENT')throw error;}if(!text.includes(pathLine)){writeFileSync(profile,text+'\n# Designli Studio CLI\n'+pathLine+'\n',{mode:0o600});}}catch{console.log('Add the PATH instruction below to your shell profile to make it permanent.');}}
  console.log('\nStudio installed. Run this once in your current terminal:\n\n  '+pathLine+'\n\nYour employee connection is ready:\n\n  cd '+quote(employee)+' && studio whoami\n\nFor a client project, use its own folder and the connection instructions in Studio.');
}catch(error){
  if(freshToken){try{await request('/auth/logout',{body:{}});}catch{}}
  console.error('\nStudio setup stopped: '+clean(error.message));process.exitCode=1;
}finally{if(scratch)rmSync(scratch,{recursive:true,force:true});}
STUDIO_BOOTSTRAP
  "$studio_node" "$studio_tmp/bootstrap.mjs" "$studio_url"
}
studio_install "$@"
