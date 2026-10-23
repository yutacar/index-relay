#!/usr/bin/env python3
"""Inspect downloaded app data and signed iOS apps. Never installs or restores on a device."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import wave


class MigrationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise MigrationError(message)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        raise MigrationError('保存情報のJSONを確認できません。元のファイルは変更しません。') from None


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
        after = os.fstat(stream.fileno())
    require((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns), '退避ファイルが読取り中に変わりました。')
    return value.hexdigest(), after.st_size


def contents(container):
    require(not container.is_symlink() and container.suffix == '.xcappdata', 'Download Containerで保存した.xcappdataを指定してください。')
    require(container.is_dir() and (container/'AppData').is_dir(), 'AppDataを含むコンテナーを指定してください。')
    files = []
    for p in container.rglob('*'):
        require(not p.is_symlink(), 'コンテナー内のシンボリックリンクは検査できません。')
        require(p.is_file() or p.is_dir(), 'コンテナーに通常のファイルではない項目があります。')
        if p.is_file():
            files.append(p)
    require(files, '空のコンテナーは検査できません。')
    return sorted(files)


def archive_summary(container):
    root = container/'AppData/Library/Application Support'
    folders = ['ReceivedRecordings', 'Transcripts', 'AutomaticRelay', 'Delivery', 'History']
    missing = [name for name in folders if not (root/name).is_dir()]
    ids = set()
    for meta in (root/'ReceivedRecordings').glob('*.json'):
        value = read_json(meta); rid = value.get('id')
        require(isinstance(rid,str) and re.fullmatch('[a-fA-F0-9]{64}',rid) and meta.stem == rid, '録音メタデータのIDが一致しません。')
        audio = meta.with_suffix('.wav')
        require(audio.is_file(), 'メタデータに対応する原音がありません。')
        try:
            with wave.open(str(audio),'rb') as wav:
                require(wav.getnchannels()==1 and wav.getsampwidth()==2 and wav.getnframes()==value.get('sampleCount') and wav.getframerate()==value.get('sampleRate'), '原音の長さ・形式とメタデータが一致しません。')
                total=0
                for chunk in iter(lambda: wav.readframes(32768), b''): total+=len(chunk)
                require(total==wav.getnframes()*2, '原音が途中で切れています。')
        except (wave.Error, EOFError):
            raise MigrationError('原音のWAV形式を確認できません。') from None
        ids.add(rid)
    require({p.stem for p in (root/'ReceivedRecordings').glob('*.wav')} == ids, 'メタデータのない原音があります。内容を確認してください。')
    transcripts = 0
    for p in (root/'Transcripts').glob('*.json'):
        value = read_json(p)
        require(value.get('recordingID') == p.stem and p.stem in ids and isinstance(value.get('text'),str) and value['text'].strip(), '文字起こしと録音の対応を確認できません。')
        transcripts += 1
    def optional(relative):
        p=root/relative
        return read_json(p) if p.is_file() else {}
    queue=optional('AutomaticRelay/state.json'); delivery=optional('Delivery/state.json'); history=optional('History/deletions.json')
    automatic=Counter(j.get('phase') for j in queue.get('jobs',{}).values())
    posts=Counter(j.get('phase') for j in delivery.get('jobs',[]))
    require(set(automatic)<=set(['queued','processing','done','needsAttention']), '認識ジョブの状態を確認できません。')
    require(set(posts)<=set(['confirmation','queued','sending','sent','retryWaiting','needsAttention','unknown','cancelled']), '送信ジョブの状態を確認できません。')
    paused=delivery.get('destinations') is not None and all(d.get('enabled') is False for d in delivery['destinations'])
    quiet=not missing and paused and queue.get('enabled') is False and not automatic['processing'] and not posts['sending'] and not history.get('pendingIDs')
    return dict(recordings=len(ids),transcripts=transcripts,missingSections=missing,
                automaticPhases=dict(automatic),deliveryPhases=dict(posts),destinationsAllDisabled=paused,
                automaticDisabled=queue.get('enabled') is False,pendingDeletions=len(history.get('pendingIDs',[])),
                quiescentSnapshot=quiet,keychainIncluded=False,osURLSessionTasksIncluded=False)


def inventory(container):
    files = contents(container)
    entries=[]
    for path in files:
        sha,size=digest(path)
        entries.append(dict(fileKey=hashlib.sha256(str(path.relative_to(container)).encode()).hexdigest(),sha256=sha,bytes=size))
    require(contents(container)==files, '検査中にコンテナーのファイル一覧が変わりました。')
    return dict(schema=1,files=sorted(entries,key=lambda e:e['fileKey']),summary=archive_summary(container))


def verify(container, manifest):
    require(manifest.get('schema')==1, '対応しないマニフェストです。')
    actual=inventory(container)
    require(actual==manifest, '退避データとマニフェストが一致しません。欠落・変更を確認してください。')
    return actual


def save(path, value):
    require(not path.exists(), '既存の検証結果は上書きしません。別の保存先を指定してください。')
    path.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w',dir=path.parent,delete=False,encoding='utf-8') as stream:
        temp=Path(stream.name);json.dump(value,stream,ensure_ascii=False,indent=2);stream.write('\n')
    try:
        os.chmod(temp,0o600)
        # A competing writer must not be overwritten.
        os.link(temp,path)
    finally:
        temp.unlink(missing_ok=True)


def build_number(value):
    require(isinstance(value,str) and re.fullmatch(r'\d+(\.\d+){0,2}',value), 'ビルド番号を数値で比較できません。')
    parts=tuple(map(int,value.split('.')))
    return parts+(0,)*(3-len(parts))


def compare(old, new, ent_old, ent_new, profile):
    bundle=old.get('CFBundleIdentifier')
    require(isinstance(bundle,str) and bundle==new.get('CFBundleIdentifier'), 'Bundle IDが一致しません。')
    require(build_number(new.get('CFBundleVersion'))>build_number(old.get('CFBundleVersion')), '新しいビルド番号を旧版より大きくしてください。')
    for ent in (ent_old,ent_new):
        appid=ent.get('application-identifier');team=ent.get('com.apple.developer.team-identifier')
        require(isinstance(appid,str) and appid.endswith('.'+bundle) and isinstance(team,str) and team, '実機用の署名identityを確認できません。')
    for field in ('application-identifier','com.apple.developer.team-identifier'):
        require(ent_old[field]==ent_new[field], '署名のApp ID prefixまたはTeamが一致しません。')
    def groups(ent):
        value=ent.get('keychain-access-groups',[ent['application-identifier']])
        require(isinstance(value,list) and value and all(isinstance(v,str) for v in value), 'Keychainグループを確認できません。')
        return value
    require(groups(ent_old)==groups(ent_new), 'Keychainアクセスグループまたは順序が一致しません。')
    for field in ('com.apple.security.application-groups','com.apple.developer.icloud-container-identifiers'):
        require(ent_old.get(field)==ent_new.get(field), '共有データ用entitlementsが一致しません。')
    for field,expected in [('UIBackgroundModes',{'bluetooth-central','processing'}),('BGTaskSchedulerPermittedIdentifiers',{bundle+'.transcribe',bundle+'.delivery.work'})]:
        require(set(new.get(field,[]))==set(old.get(field,[])) and expected<=set(new.get(field,[])), 'バックグラウンド設定が一致しません。')
    require(new.get('NSBluetoothAlwaysUsageDescription'), 'Bluetoothの利用目的がありません。')
    require('iPhoneOS' in new.get('CFBundleSupportedPlatforms',[]), '実機用の候補アプリではありません。')
    expires=profile.get('ExpirationDate')
    require(isinstance(expires,datetime), '候補のプロビジョニング有効期限を確認できません。')
    if expires.tzinfo is None: expires=expires.replace(tzinfo=timezone.utc)
    require(expires>datetime.now(timezone.utc), '候補のプロビジョニングが失効しています。')
    require(ent_new['com.apple.developer.team-identifier'] in profile.get('TeamIdentifier',[]), '候補のプロビジョニングTeamが一致しません。')
    allowed=profile.get('Entitlements',{})
    require(fnmatch.fnmatchcase(ent_new['application-identifier'],allowed.get('application-identifier','')), '候補の署名とプロビジョニングApp IDが一致しません。')
    require(all(any(fnmatch.fnmatchcase(group,pattern) for pattern in allowed.get('keychain-access-groups',[])) for group in groups(ent_new)), '候補のKeychainグループがプロビジョニングにありません。')
    require(ent_new.get('get-task-allow',False)==allowed.get('get-task-allow',False), '候補のデバッグ権限とプロビジョニングが一致しません。')
    return dict(artifactChecksPassed=True,bundleIdentifierMatches=True,appPrefixAndTeamMatch=True,
                orderedKeychainGroupsMatch=True,backgroundConfigurationMatches=True,profileUnexpired=True,
                buildIncreased=True,deviceProfileMembershipVerified=False,deviceKeychainContinuityVerified=False,
                readyForDeviceUpdate=False)


def signed_app(app):
    require(app.is_dir() and not app.is_symlink(), '.appディレクトリを指定してください。')
    def command(args):
        p=subprocess.run(args,capture_output=True,timeout=60)
        require(p.returncode==0, '実機用アプリの署名またはプロビジョニングを検証できません。')
        return p.stdout
    command(['codesign','--verify','--deep','--strict',str(app)])
    info=plistlib.loads((app/'Info.plist').read_bytes())
    ent=plistlib.loads(command(['codesign','-d','--entitlements',':-',str(app)]))
    return info,ent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    for name in ('seal','verify'):
        p=sub.add_parser(name);p.add_argument('--container',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True)
    p=sub.add_parser('preflight');p.add_argument('--old-app',type=Path,required=True);p.add_argument('--new-app',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.command=='preflight':
            old,ent_old=signed_app(args.old_app);new,ent_new=signed_app(args.new_app)
            p=subprocess.run(['security','cms','-D','-i',str(args.new_app/'embedded.mobileprovision')],capture_output=True,timeout=60)
            require(p.returncode==0, '候補のプロビジョニングを読み取れません。')
            result=compare(old,new,ent_old,ent_new,plistlib.loads(p.stdout));save(args.report,result)
        elif args.command=='seal':
            require(not args.manifest.resolve().is_relative_to(args.container.resolve()), 'マニフェストはコンテナーの外へ保存してください。')
            data=inventory(args.container);save(args.manifest,data);result={'integrityRecorded':True,**data['summary']}
        else:
            data=verify(args.container,read_json(args.manifest));result={'integrityVerified':True,**data['summary']}
        print(json.dumps(result,ensure_ascii=False,indent=2))
    except (MigrationError,OSError,ValueError,TypeError,KeyError,AttributeError,subprocess.SubprocessError,plistlib.InvalidFileException) as error:
        # Never echo exception text: malformed input can contain a token or transcript.
        message=str(error) if isinstance(error,MigrationError) else 'コンテナー・保存形式・署名を確認できません。'
        parser.exit(1,message+' 元データは変更していません。\n')


if __name__=='__main__': main()
