"""Validate public client configuration before any build or network request."""
import base64
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

PUBLIC_FIELDS = {'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY',
                 'GOOGLE_WEB_CLIENT_ID'}
APP_FIELDS = PUBLIC_FIELDS | {'FCM_ENABLED', 'FIREBASE_API_KEY', 'FIREBASE_APP_ID',
    'FIREBASE_SENDER_ID', 'FIREBASE_PROJECT_ID', 'PRIVACY_POLICY_URL',
    'ACCOUNT_DELETION_URL', 'SUPPORT_EMAIL'}


def public_key(value):
    if not isinstance(value, str) or any(c.isspace() for c in value):
        return False
    if value.startswith('sb_publishable_') and len(value) > 20:
        return True
    try:
        parts = value.split('.')
        if len(parts) != 3 or not all(parts):
            return False
        payload = json.loads(base64.urlsafe_b64decode(parts[1] + '==='))
        return isinstance(payload, dict) and payload.get('role') == 'anon'
    except (ValueError, UnicodeError):
        return False


def https_url(value, origin_only=False):
    if not isinstance(value, str) or any(c.isspace() for c in value):
        return False
    try:
        parsed = urlsplit(value)
        _ = parsed.port
        return (parsed.scheme == 'https' and bool(parsed.hostname)
                and not parsed.username and not parsed.password and not parsed.fragment
                and (not origin_only or (not parsed.query and parsed.path in ('', '/'))))
    except ValueError:
        return False


def load_public_config(path, *, app=True):
    try:
        config = json.loads(Path(path).read_text())
    except (OSError, ValueError, UnicodeError):
        raise ValueError('Cannot read config: use a valid JSON object with public client settings.') from None
    if not isinstance(config, dict) or set(config) - (APP_FIELDS if app else PUBLIC_FIELDS):
        raise ValueError('Use only documented public client settings; remove unknown or server-only fields.')
    keys = [config[k] for k in ('SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY') if k in config]
    if not keys or not all(public_key(key) for key in keys):
        raise ValueError('Refusing invalid or privileged keys: every Supabase key must be public publishable/anon.')
    if not https_url(config.get('SUPABASE_URL'), origin_only=True):
        raise ValueError('Use an HTTPS Supabase origin without credentials, path, query or fragment.')
    for field, value in config.items():
        if field == 'FCM_ENABLED':
            if not isinstance(value, bool):
                raise ValueError('FCM_ENABLED must be a JSON boolean.')
        elif not isinstance(value, str):
            raise ValueError('Public client settings must be strings (except FCM_ENABLED).')
    for field in ('PRIVACY_POLICY_URL', 'ACCOUNT_DELETION_URL'):
        if field in config and not https_url(config[field]):
            raise ValueError('Policy and deletion links must be public HTTPS URLs.')
    if 'GOOGLE_WEB_CLIENT_ID' in config and not re.fullmatch(
        r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com',
        config['GOOGLE_WEB_CLIENT_ID'],
    ):
        raise ValueError('GOOGLE_WEB_CLIENT_ID must be the public Google Web OAuth client ID.')
    return config
