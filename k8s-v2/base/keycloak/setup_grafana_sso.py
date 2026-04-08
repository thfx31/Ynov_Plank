#!/usr/bin/env python3
"""Configure a Keycloak realm/client for Grafana SSO and seed sample users."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass


class KeycloakError(RuntimeError):
    pass


@dataclass
class UserSpec:
    username: str
    email: str
    first_name: str
    last_name: str
    password: str
    roles: list[str]
    temporary: bool = False


class KC:
    def __init__(self, base_url: str, admin_user: str, admin_password: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = self._login(admin_user, admin_password)

    def _request(self, method: str, path: str, *, data=None, form=None, expected=None):
        headers = {"Authorization": f"Bearer {self.token}"} if hasattr(self, "token") else {}
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(data).encode()
        elif form is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = urllib.parse.urlencode(form).encode()
        req = urllib.request.Request(self.base_url + path, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req) as resp:
                payload = resp.read().decode()
                code = resp.getcode()
                hdrs = dict(resp.headers.items())
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", errors="replace")
            code = exc.code
            hdrs = dict(exc.headers.items())
            if expected is None or code not in expected:
                raise KeycloakError(f"{method} {path} failed with {code}: {payload}") from exc
        if expected is not None and code not in expected:
            raise KeycloakError(f"{method} {path} returned {code}: {payload}")
        return code, payload, hdrs

    def _login(self, user: str, password: str) -> str:
        req = urllib.request.Request(
            self.base_url + "/realms/master/protocol/openid-connect/token",
            data=urllib.parse.urlencode(
                {
                    "client_id": "admin-cli",
                    "grant_type": "password",
                    "username": user,
                    "password": password,
                }
            ).encode(),
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())["access_token"]

    def ensure_realm(self, realm: str) -> None:
        self._request("GET", f"/admin/realms/{urllib.parse.quote(realm)}", expected={200, 404})
        try:
            self._request("GET", f"/admin/realms/{urllib.parse.quote(realm)}", expected={200})
            print(f"[ok] realm {realm} already exists")
        except KeycloakError:
            self._request(
                "POST",
                "/admin/realms",
                data={"realm": realm, "enabled": True, "registrationAllowed": False},
                expected={201},
            )
            print(f"[done] created realm {realm}")

    def ensure_role(self, realm: str, role_name: str) -> None:
        try:
            self._request("GET", f"/admin/realms/{urllib.parse.quote(realm)}/roles/{urllib.parse.quote(role_name)}", expected={200})
            print(f"[ok] role {role_name} exists")
        except KeycloakError:
            self._request(
                "POST",
                f"/admin/realms/{urllib.parse.quote(realm)}/roles",
                data={"name": role_name},
                expected={201},
            )
            print(f"[done] created role {role_name}")

    def ensure_client(self, realm: str, client_secret: str) -> None:
        path = f"/admin/realms/{urllib.parse.quote(realm)}/clients?clientId=grafana-oauth"
        _, payload, _ = self._request("GET", path, expected={200})
        clients = json.loads(payload)
        client = clients[0] if clients else None
        desired = {
            "clientId": "grafana-oauth",
            "name": "Grafana OAuth",
            "protocol": "openid-connect",
            "enabled": True,
            "publicClient": False,
            "secret": client_secret,
            "redirectUris": ["http://localhost:3000/login/generic_oauth"],
            "webOrigins": ["http://localhost:3000"],
            "baseUrl": "http://localhost:3000",
            "adminUrl": "http://localhost:3000",
            "rootUrl": "http://localhost:3000",
            "standardFlowEnabled": True,
            "directAccessGrantsEnabled": False,
            "serviceAccountsEnabled": False,
            "attributes": {
                "post.logout.redirect.uris": "http://localhost:3000",
            },
            "defaultClientScopes": ["profile", "email", "roles", "web-origins"],
        }
        if client:
            client_id = client["id"]
            self._request(
                "PUT",
                f"/admin/realms/{urllib.parse.quote(realm)}/clients/{urllib.parse.quote(client_id)}",
                data={**client, **desired},
                expected={204},
            )
            print("[done] updated client grafana-oauth")
        else:
            self._request(
                "POST",
                f"/admin/realms/{urllib.parse.quote(realm)}/clients",
                data=desired,
                expected={201},
            )
            print("[done] created client grafana-oauth")

    def _find_user(self, realm: str, username: str):
        _, payload, _ = self._request(
            "GET",
            f"/admin/realms/{urllib.parse.quote(realm)}/users?username={urllib.parse.quote(username)}&exact=true",
            expected={200},
        )
        users = json.loads(payload)
        return users[0] if users else None

    def _get_role(self, realm: str, role_name: str):
        _, payload, _ = self._request(
            "GET",
            f"/admin/realms/{urllib.parse.quote(realm)}/roles/{urllib.parse.quote(role_name)}",
            expected={200},
        )
        return json.loads(payload)

    def ensure_user(self, realm: str, user: UserSpec) -> None:
        existing = self._find_user(realm, user.username)
        payload = {
            "username": user.username,
            "email": user.email,
            "firstName": user.first_name,
            "lastName": user.last_name,
            "enabled": True,
            "emailVerified": True,
            "requiredActions": [] if not user.temporary else ["UPDATE_PASSWORD"],
        }
        if existing:
            user_id = existing["id"]
            self._request(
                "PUT",
                f"/admin/realms/{urllib.parse.quote(realm)}/users/{urllib.parse.quote(user_id)}",
                data=payload,
                expected={204},
            )
            print(f"[done] updated user {user.username}")
        else:
            _, _, headers = self._request(
                "POST",
                f"/admin/realms/{urllib.parse.quote(realm)}/users",
                data=payload,
                expected={201},
            )
            user_id = headers["Location"].rstrip("/").split("/")[-1]
            print(f"[done] created user {user.username}")

        self._request(
            "PUT",
            f"/admin/realms/{urllib.parse.quote(realm)}/users/{urllib.parse.quote(user_id)}/reset-password",
            data={"type": "password", "value": user.password, "temporary": user.temporary},
            expected={204},
        )

        roles = [self._get_role(realm, name) for name in user.roles]
        self._request(
            "POST",
            f"/admin/realms/{urllib.parse.quote(realm)}/users/{urllib.parse.quote(user_id)}/role-mappings/realm",
            data=roles,
            expected={204},
        )
        print(f"[done] ensured roles {', '.join(user.roles)} for {user.username}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Setup Keycloak realm/client/users for Grafana SSO")
    parser.add_argument("--base-url", default="http://localhost:8003")
    parser.add_argument("--admin-user", default="admin")
    parser.add_argument("--admin-password", default="ChangeThisAdminPassword!")
    parser.add_argument("--realm", default="Grafana")
    parser.add_argument("--client-secret", default="grafana-local-client-secret")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        kc = KC(args.base_url, args.admin_user, args.admin_password)
        kc.ensure_realm(args.realm)
        for role in ["platform-admin", "manager", "user"]:
            kc.ensure_role(args.realm, role)
        kc.ensure_client(args.realm, args.client_secret)

        users = [
            UserSpec(
                username="jean.dupont@exemple.com",
                email="jean.dupont@exemple.com",
                first_name="Jean",
                last_name="Dupont",
                password="AlgoHiveGrafana1!",
                roles=["platform-admin"],
                temporary=False,
            ),
            UserSpec(
                username="marie.martin@exemple.com",
                email="marie.martin@exemple.com",
                first_name="Marie",
                last_name="Martin",
                password="AlgoHiveGrafana1!",
                roles=["user"],
                temporary=False,
            ),
        ]
        for user in users:
            kc.ensure_user(args.realm, user)
        print("Grafana SSO setup completed successfully")
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
