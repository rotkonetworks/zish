#!/usr/bin/env python3
"""Generate synthetic shell command training data. Pure algorithmic, no API calls.

Outputs JSONL to stdout: {"text": "..."}
Prints count to stderr.
"""

import json
import random
import sys
import string

# ---------------------------------------------------------------------------
# Vocabulary pools
# ---------------------------------------------------------------------------

DIRS = [
    "src", "lib", "bin", "docs", "config", "test", "build", "dist", "assets",
    "public", "scripts", "utils", "core", "internal", "pkg", "cmd", "api",
    "app", "web", "server", "client", "common", "shared", "models", "views",
    "controllers", "services", "middleware", "handlers", "routes", "static",
    "templates", "migrations", "fixtures", "vendor", "third_party", "tools",
    "deploy", "infra", "ci", "data", "tmp", "cache", "logs", "backup",
    "include", "examples", "benchmarks", "proto", "generated", "target",
    "out", "node_modules", ".github", "workflows", "hooks", "plugins",
]

EXTS = [
    ".py", ".js", ".ts", ".go", ".rs", ".zig", ".c", ".h", ".json", ".yaml",
    ".toml", ".md", ".txt", ".log", ".sh", ".css", ".html", ".jsx", ".tsx",
    ".vue", ".rb", ".java", ".kt", ".swift", ".cpp", ".hpp", ".sql", ".xml",
    ".env", ".cfg", ".ini", ".lock", ".csv", ".proto", ".graphql", ".tf",
    ".dockerfile", ".makefile",
]

BASENAMES = [
    "main", "index", "app", "server", "client", "config", "utils", "helpers",
    "types", "models", "schema", "handler", "controller", "service", "router",
    "middleware", "auth", "db", "database", "cache", "logger", "errors",
    "constants", "settings", "setup", "init", "run", "build", "test",
    "bench", "lint", "format", "deploy", "migrate", "seed", "factory",
    "fixture", "mock", "stub", "worker", "queue", "consumer", "producer",
    "parser", "lexer", "compiler", "codegen", "transform", "visitor",
    "adapter", "bridge", "proxy", "decorator", "observer", "strategy",
    "command", "context", "state", "request", "response", "payload",
    "validator", "sanitizer", "encoder", "decoder", "serializer",
    "README", "LICENSE", "CHANGELOG", "Makefile", "Dockerfile",
    "docker-compose", "package", "tsconfig", "webpack", "babel",
    "eslint", "prettier", ".gitignore", "requirements", "Cargo",
    "go.mod", "go.sum", "build.zig", "flake", "shell",
]

BRANCH_PREFIXES = [
    "feature/", "fix/", "bugfix/", "hotfix/", "chore/", "refactor/",
    "docs/", "test/", "ci/", "release/", "experiment/", "wip/",
]

BRANCH_NAMES = [
    "auth", "login", "signup", "dashboard", "api-v2", "migration",
    "dark-mode", "caching", "perf", "cleanup", "docker", "ci-cd",
    "typescript", "eslint", "tests", "e2e", "graphql", "rest-api",
    "websocket", "notifications", "search", "pagination", "upload",
    "download", "export", "import", "backup", "logging", "monitoring",
    "rate-limiting", "cors", "auth-middleware", "error-handling",
    "user-profile", "settings-page", "admin-panel", "payment",
    "subscription", "email-service", "queue-worker", "batch-processing",
    "data-pipeline", "analytics", "reporting", "i18n", "a11y",
    "responsive", "mobile", "pwa", "ssr", "ssg", "edge-functions",
    "add-users-endpoint", "fix-null-pointer", "update-deps",
    "refactor-db-layer", "improve-error-messages", "add-retry-logic",
]

COMMIT_VERBS = ["fix", "add", "update", "refactor", "remove", "implement",
                "improve", "clean up", "optimize", "simplify", "extract",
                "rename", "move", "split", "merge", "revert", "bump",
                "upgrade", "downgrade", "configure", "enable", "disable",
                "document", "test", "benchmark", "lint", "format",
                "deprecate", "migrate", "scaffold", "bootstrap", "wire up"]

COMMIT_OBJECTS = [
    "authentication flow", "error handling", "database schema", "API endpoint",
    "middleware", "config loader", "test suite", "CI pipeline", "Docker setup",
    "logging", "caching layer", "rate limiter", "input validation",
    "user model", "session management", "password hashing", "JWT tokens",
    "CORS headers", "request parsing", "response serialization",
    "file upload handler", "email service", "queue worker", "batch job",
    "data migration", "search index", "pagination logic", "WebSocket handler",
    "notification system", "payment integration", "subscription logic",
    "admin dashboard", "settings page", "user profile", "analytics tracker",
    "performance metrics", "health check endpoint", "graceful shutdown",
    "retry logic", "circuit breaker", "connection pool", "memory leak",
    "race condition", "deadlock", "null pointer", "off-by-one error",
    "type definitions", "build script", "deploy workflow", "release process",
    "dependency versions", "README", "CHANGELOG", "contributing guide",
    "linter config", "formatter settings", "git hooks", "pre-commit checks",
]

NPM_PACKAGES = [
    "express", "react", "vue", "angular", "next", "nuxt", "svelte",
    "typescript", "webpack", "vite", "esbuild", "rollup", "babel",
    "eslint", "prettier", "jest", "vitest", "mocha", "chai", "sinon",
    "axios", "node-fetch", "lodash", "dayjs", "moment", "zod", "yup",
    "prisma", "sequelize", "mongoose", "knex", "pg", "mysql2", "redis",
    "bull", "socket.io", "ws", "cors", "helmet", "morgan", "winston",
    "pino", "dotenv", "uuid", "nanoid", "bcrypt", "jsonwebtoken",
    "passport", "multer", "sharp", "puppeteer", "playwright",
    "tailwindcss", "postcss", "autoprefixer", "sass", "styled-components",
    "@types/node", "@types/react", "@types/express", "tsx", "nodemon",
    "concurrently", "cross-env", "rimraf", "chalk", "commander", "inquirer",
    "ora", "boxen", "execa", "globby", "fast-glob", "chokidar",
]

PIP_PACKAGES = [
    "flask", "django", "fastapi", "uvicorn", "gunicorn", "requests",
    "httpx", "aiohttp", "sqlalchemy", "alembic", "psycopg2-binary",
    "pymongo", "redis", "celery", "pydantic", "marshmallow", "pytest",
    "pytest-cov", "pytest-asyncio", "black", "ruff", "mypy", "isort",
    "flake8", "pylint", "bandit", "numpy", "pandas", "scipy",
    "scikit-learn", "torch", "transformers", "pillow", "boto3",
    "click", "typer", "rich", "tqdm", "python-dotenv", "pyjwt",
    "bcrypt", "cryptography", "paramiko", "fabric", "ansible",
    "docker", "kubernetes", "prometheus-client", "sentry-sdk",
    "structlog", "loguru", "tenacity", "cachetools",
]

CARGO_CRATES = [
    "serde", "serde_json", "tokio", "async-std", "reqwest", "hyper",
    "axum", "actix-web", "warp", "rocket", "diesel", "sqlx",
    "sea-orm", "redis", "clap", "structopt", "anyhow", "thiserror",
    "tracing", "log", "env_logger", "chrono", "uuid", "rand",
    "regex", "lazy_static", "once_cell", "parking_lot", "crossbeam",
    "rayon", "itertools", "bytes", "futures", "pin-project",
    "tower", "tonic", "prost", "config", "dotenv",
]

DOCKER_IMAGES = [
    "nginx", "redis", "postgres", "mysql", "mongo", "elasticsearch",
    "rabbitmq", "kafka", "zookeeper", "consul", "vault", "traefik",
    "caddy", "haproxy", "grafana", "prometheus", "loki", "jaeger",
    "node:20", "node:18-alpine", "python:3.12", "python:3.11-slim",
    "golang:1.22", "rust:1.76", "ubuntu:22.04", "debian:bookworm-slim",
    "alpine:3.19", "busybox", "memcached", "minio/minio",
    "dpage/pgadmin4", "portainer/portainer-ce", "gitea/gitea",
]

HOSTNAMES = [
    "server1", "web01", "db01", "cache01", "worker01", "proxy01",
    "staging", "production", "dev", "ci", "monitor", "backup",
    "gateway", "bastion", "jump", "vpn", "mail", "dns",
]

DOMAINS = [
    "example.com", "myapp.io", "internal.dev", "company.net",
    "cloud.local", "staging.app", "prod.services", "infra.internal",
]

USERS = ["root", "admin", "deploy", "ubuntu", "ec2-user", "centos", "app", "www-data"]

SERVICES = [
    "nginx", "postgresql", "mysql", "redis-server", "docker",
    "sshd", "cron", "systemd-resolved", "NetworkManager",
    "firewalld", "ufw", "fail2ban", "postfix", "dovecot",
    "prometheus", "grafana-server", "elasticsearch", "kibana",
    "rabbitmq-server", "mongod", "apache2", "httpd", "php-fpm",
    "gunicorn", "supervisord", "containerd", "kubelet",
]

GREP_PATTERNS = [
    "TODO", "FIXME", "HACK", "BUG", "XXX", "WARN", "ERROR",
    "deprecated", "unsafe", "panic", "unwrap", "expect",
    r"import\s+", r"from\s+\w+\s+import", r"require\(", r"use\s+",
    r"def\s+\w+", r"fn\s+\w+", r"func\s+\w+", r"function\s+\w+",
    r"class\s+\w+", r"struct\s+\w+", r"enum\s+\w+", r"trait\s+\w+",
    r"interface\s+\w+", r"type\s+\w+", "password", "secret", "token",
    "api_key", "endpoint", "localhost", r"127\.0\.0\.1", r"0\.0\.0\.0",
    r"port\s*=", r"host\s*=", r"debug\s*=", r"console\.log",
    "print(", "println!", "fmt.Print", r"log\.", r"logger\.",
]

MAKE_TARGETS = [
    "all", "build", "test", "clean", "install", "run", "dev", "lint",
    "format", "check", "release", "debug", "bench", "docs", "deploy",
    "docker", "docker-build", "docker-push", "proto", "generate",
    "migrate", "seed", "coverage", "ci", "help",
]

URLS = [
    "https://api.example.com/v1/users",
    "https://api.example.com/v1/auth/login",
    "https://api.example.com/v2/data",
    "http://localhost:8080/health",
    "http://localhost:3000/api/status",
    "https://registry.npmjs.org/",
    "https://pypi.org/simple/",
    "https://raw.githubusercontent.com/user/repo/main/file",
    "https://github.com/user/repo/releases/latest",
    "https://download.example.com/release.tar.gz",
]

PERMISSIONS = ["644", "755", "600", "700", "400", "664", "775", "777", "550", "640"]

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def rand_path(depth_range=(1, 4), with_ext=True):
    """Generate a random realistic file path."""
    depth = random.randint(*depth_range)
    parts = []
    for _ in range(depth - 1):
        parts.append(random.choice(DIRS))
    if with_ext:
        base = random.choice(BASENAMES)
        ext = random.choice(EXTS)
        # Some basenames already have extensions or are special
        if base in ("Makefile", "Dockerfile", ".gitignore", "LICENSE"):
            parts.append(base)
        else:
            parts.append(base + ext)
    else:
        parts.append(random.choice(DIRS))
    prefix = random.choice(["./", "", "/home/user/project/", "~/projects/myapp/"])
    return prefix + "/".join(parts)


def rand_dir(depth_range=(1, 3)):
    """Generate a random directory path."""
    return rand_path(depth_range, with_ext=False)


def rand_branch():
    """Generate a random branch name."""
    if random.random() < 0.3:
        return random.choice(["main", "master", "develop", "staging", "production"])
    return random.choice(BRANCH_PREFIXES) + random.choice(BRANCH_NAMES)


def rand_commit_msg():
    """Generate a random commit message."""
    verb = random.choice(COMMIT_VERBS)
    obj = random.choice(COMMIT_OBJECTS)
    return f"{verb} {obj}"


def rand_host():
    """Generate a random host string."""
    if random.random() < 0.5:
        return f"{random.choice(USERS)}@{random.choice(HOSTNAMES)}.{random.choice(DOMAINS)}"
    return f"{random.choice(USERS)}@{random.choice(HOSTNAMES)}"


def rand_port():
    return random.choice([22, 80, 443, 3000, 3306, 5432, 5672, 6379, 8000, 8080, 8443, 9090, 9200, 27017])


def rand_number(lo=1, hi=20):
    return random.randint(lo, hi)


def emit(text):
    """Emit a single training example."""
    print(json.dumps({"text": text}))


def emit_with_prefixes(cmd, count_range=(2, 4)):
    """Emit a command and several prefix-completion pairs."""
    emit(f"$ {cmd}")
    results = [f"$ {cmd}"]
    # Generate prefix splits
    tokens = cmd.split()
    if len(tokens) < 2:
        return results
    n_prefixes = min(random.randint(*count_range), len(tokens) - 1)
    splits = sorted(random.sample(range(1, len(tokens)), min(n_prefixes, len(tokens) - 1)))
    for s in splits:
        prefix = " ".join(tokens[:s])
        text = f"$ {prefix}"
        emit(text)
        results.append(text)
    return results


# ---------------------------------------------------------------------------
# Category generators
# ---------------------------------------------------------------------------

def gen_file_ops(n):
    """Generate file operation commands."""
    count = 0
    while count < n:
        op = random.choice([
            "cp", "cp", "mv", "mv", "rm", "rm",
            "mkdir", "rmdir", "touch", "chmod", "chown", "ln",
        ])
        if op == "cp":
            flags = random.choice(["", "-r", "-a", "-v", "-rv", "-i"])
            src = rand_path()
            dst = rand_path() if random.random() < 0.5 else rand_dir()
            cmd = f"cp {flags} {src} {dst}".replace("  ", " ").strip()
        elif op == "mv":
            flags = random.choice(["", "-v", "-i", "-n"])
            src = rand_path()
            dst = rand_path() if random.random() < 0.3 else rand_dir()
            cmd = f"mv {flags} {src} {dst}".replace("  ", " ").strip()
        elif op == "rm":
            flags = random.choice(["", "-f", "-r", "-rf", "-rv", "-i"])
            target = rand_path() if random.random() < 0.6 else rand_dir()
            cmd = f"rm {flags} {target}".replace("  ", " ").strip()
        elif op == "mkdir":
            flags = random.choice(["", "-p", "-pv"])
            cmd = f"mkdir {flags} {rand_dir()}".replace("  ", " ").strip()
        elif op == "rmdir":
            cmd = f"rmdir {rand_dir()}"
        elif op == "touch":
            cmd = f"touch {rand_path()}"
        elif op == "chmod":
            perm = random.choice(PERMISSIONS)
            flags = random.choice(["", "-R"])
            target = rand_path() if random.random() < 0.6 else rand_dir()
            cmd = f"chmod {flags} {perm} {target}".replace("  ", " ").strip()
        elif op == "chown":
            user = random.choice(USERS)
            group = random.choice(["", f":{user}", ":www-data", ":docker"])
            flags = random.choice(["", "-R"])
            target = rand_path() if random.random() < 0.5 else rand_dir()
            cmd = f"chown {flags} {user}{group} {target}".replace("  ", " ").strip()
        elif op == "ln":
            flags = random.choice(["-s", "-sf", "-sv"])
            cmd = f"ln {flags} {rand_path()} {rand_path()}"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_git(n):
    """Generate git commands."""
    count = 0
    while count < n:
        sub = random.choices(
            ["commit", "checkout", "branch", "merge", "rebase", "log",
             "diff", "stash", "push", "pull", "fetch", "add", "status",
             "reset", "cherry-pick", "tag", "remote", "clone", "init",
             "show", "blame", "bisect", "clean", "worktree", "switch"],
            weights=[15, 10, 8, 8, 6, 10, 10, 8, 8, 6, 4, 10, 5,
                     5, 3, 4, 3, 3, 2, 4, 4, 2, 2, 2, 3],
        )[0]

        if sub == "commit":
            msg = rand_commit_msg()
            flags = random.choice(["", "-a", "--amend", "-a --amend", "--no-edit --amend"])
            cmd = f'git commit {flags} -m "{msg}"'.replace("  ", " ").strip()
        elif sub == "checkout":
            if random.random() < 0.4:
                cmd = f"git checkout -b {rand_branch()}"
            elif random.random() < 0.3:
                cmd = f"git checkout -- {rand_path()}"
            else:
                cmd = f"git checkout {rand_branch()}"
        elif sub == "switch":
            if random.random() < 0.4:
                cmd = f"git switch -c {rand_branch()}"
            else:
                cmd = f"git switch {rand_branch()}"
        elif sub == "branch":
            if random.random() < 0.3:
                cmd = f"git branch -d {rand_branch()}"
            elif random.random() < 0.3:
                cmd = f"git branch -D {rand_branch()}"
            elif random.random() < 0.3:
                cmd = "git branch -a"
            elif random.random() < 0.5:
                cmd = "git branch --list"
            else:
                cmd = f"git branch {rand_branch()}"
        elif sub == "merge":
            flags = random.choice(["", "--no-ff", "--squash", "--abort"])
            if flags == "--abort":
                cmd = "git merge --abort"
            else:
                cmd = f"git merge {flags} {rand_branch()}".replace("  ", " ").strip()
        elif sub == "rebase":
            if random.random() < 0.3:
                cmd = f"git rebase -i HEAD~{rand_number(2, 10)}"
            elif random.random() < 0.3:
                cmd = "git rebase --abort"
            elif random.random() < 0.3:
                cmd = "git rebase --continue"
            else:
                cmd = f"git rebase {rand_branch()}"
        elif sub == "log":
            fmt = random.choice([
                "--oneline", "--oneline --graph", "--oneline --graph --all",
                "--pretty=format:'%h %s'", "--stat", "-p", "--graph --decorate",
            ])
            limit = random.choice(["", f"-n {rand_number(5, 30)}", f"-{rand_number(5, 20)}"])
            cmd = f"git log {fmt} {limit}".replace("  ", " ").strip()
        elif sub == "diff":
            variant = random.choice([
                "", "--stat", "--cached", "--staged", "--name-only",
                f"HEAD~{rand_number(1, 5)}", f"{rand_branch()}..HEAD",
                f"-- {rand_path()}", "--shortstat",
            ])
            cmd = f"git diff {variant}".strip()
        elif sub == "stash":
            action = random.choice(["", "pop", "list", "drop", "apply", "show",
                                     f"push -m '{rand_commit_msg()}'"])
            cmd = f"git stash {action}".strip()
        elif sub == "push":
            variant = random.choice([
                "", "-u origin main", "-u origin HEAD", "--force-with-lease",
                f"origin {rand_branch()}", "--tags", "--force",
                f"-u origin {rand_branch()}",
            ])
            cmd = f"git push {variant}".strip()
        elif sub == "pull":
            variant = random.choice([
                "", "--rebase", "origin main", f"origin {rand_branch()}",
                "--rebase origin main", "--ff-only",
            ])
            cmd = f"git pull {variant}".strip()
        elif sub == "fetch":
            variant = random.choice(["", "--all", "--prune", "origin", "--tags"])
            cmd = f"git fetch {variant}".strip()
        elif sub == "add":
            target = random.choice([
                ".", "-A", "-u", rand_path(), rand_path(),
                f"{rand_path()} {rand_path()}", "-p",
                f"*.{random.choice(['py','js','ts','go','rs'])}",
            ])
            cmd = f"git add {target}"
        elif sub == "status":
            flags = random.choice(["", "-s", "--short", "-sb"])
            cmd = f"git status {flags}".strip()
        elif sub == "reset":
            variant = random.choice([
                f"HEAD~{rand_number(1, 5)}",
                f"--soft HEAD~{rand_number(1, 3)}",
                f"--hard HEAD~{rand_number(1, 3)}",
                f"--hard origin/main",
                f"-- {rand_path()}",
                "HEAD",
            ])
            cmd = f"git reset {variant}"
        elif sub == "cherry-pick":
            # fake sha
            sha = ''.join(random.choices("0123456789abcdef", k=7))
            cmd = f"git cherry-pick {sha}"
        elif sub == "tag":
            ver = f"v{random.randint(0,9)}.{random.randint(0,30)}.{random.randint(0,20)}"
            if random.random() < 0.3:
                cmd = f'git tag -a {ver} -m "Release {ver}"'
            elif random.random() < 0.3:
                cmd = "git tag --list"
            else:
                cmd = f"git tag {ver}"
        elif sub == "remote":
            action = random.choice([
                "-v", "add origin https://github.com/user/repo.git",
                "remove origin", "set-url origin https://github.com/user/repo.git",
                "show origin",
            ])
            cmd = f"git remote {action}"
        elif sub == "clone":
            repo = random.choice([
                "https://github.com/user/repo.git",
                "https://github.com/user/repo",
                f"git@github.com:user/{random.choice(BASENAMES)}.git",
            ])
            flags = random.choice(["", "--depth 1", "--bare", "--recursive", "--branch main"])
            cmd = f"git clone {flags} {repo}".replace("  ", " ").strip()
        elif sub == "init":
            cmd = random.choice(["git init", "git init .", f"git init {random.choice(DIRS)}"])
        elif sub == "show":
            target = random.choice([
                "HEAD", f"HEAD~{rand_number(1, 5)}", f"HEAD:{rand_path()}",
                ''.join(random.choices("0123456789abcdef", k=7)),
            ])
            cmd = f"git show {target}"
        elif sub == "blame":
            cmd = f"git blame {rand_path()}"
        elif sub == "bisect":
            action = random.choice(["start", "good", "bad", "reset", "run"])
            cmd = f"git bisect {action}"
        elif sub == "clean":
            flags = random.choice(["-fd", "-fxd", "-n", "-nd"])
            cmd = f"git clean {flags}"
        elif sub == "worktree":
            action = random.choice([
                f"add ../worktree-{random.choice(BRANCH_NAMES)} {rand_branch()}",
                "list", "prune",
            ])
            cmd = f"git worktree {action}"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_package_managers(n):
    """Generate package manager commands."""
    count = 0
    while count < n:
        pm = random.choices(
            ["npm", "yarn", "pnpm", "pip", "cargo", "apt", "pacman", "dnf"],
            weights=[20, 10, 10, 20, 15, 10, 8, 7],
        )[0]

        if pm in ("npm", "yarn", "pnpm"):
            action = random.choices(
                ["install", "add", "remove", "run", "i", "init", "list", "outdated",
                 "audit", "publish", "link", "unlink", "exec", "dlx", "create"],
                weights=[15, 15, 8, 20, 5, 3, 3, 3, 3, 2, 2, 2, 3, 3, 3],
            )[0]
            if action in ("install", "i"):
                if random.random() < 0.4:
                    cmd = f"{pm} install"
                else:
                    pkg = random.choice(NPM_PACKAGES)
                    flags = random.choice(["", "-D", "--save-dev", "-g", "--save-exact"])
                    cmd = f"{pm} {'add' if pm in ('yarn','pnpm') else 'install'} {flags} {pkg}".replace("  ", " ").strip()
            elif action == "add":
                pkg = random.choice(NPM_PACKAGES)
                flags = random.choice(["", "-D", "--save-dev", "-g"])
                cmd = f"{pm} add {flags} {pkg}".replace("  ", " ").strip()
            elif action == "remove":
                pkg = random.choice(NPM_PACKAGES)
                cmd = f"{pm} {'remove' if pm != 'yarn' else 'remove'} {pkg}"
            elif action == "run":
                script = random.choice(["build", "test", "dev", "start", "lint", "format",
                                         "typecheck", "preview", "e2e", "storybook",
                                         "generate", "migrate", "seed", "clean"])
                cmd = f"{pm} run {script}"
            elif action == "exec":
                tool = random.choice(["tsc", "eslint", "prettier", "jest", "vitest", "tsx"])
                cmd = f"{pm} exec {tool}"
            elif action == "dlx":
                tool = random.choice(["create-react-app", "create-next-app", "degit", "tsx"])
                cmd = f"npx {tool}" if pm == "npm" else f"{pm} dlx {tool}"
            elif action == "create":
                template = random.choice(["vite", "next-app", "remix", "astro"])
                cmd = f"{pm} create {template} my-app"
            else:
                cmd = f"{pm} {action}"

        elif pm == "pip":
            action = random.choices(
                ["install", "install -r", "uninstall", "freeze", "list", "show",
                 "install --upgrade", "install -e"],
                weights=[25, 15, 8, 8, 5, 5, 10, 4],
            )[0]
            if action == "install":
                pkg = random.choice(PIP_PACKAGES)
                flags = random.choice(["", "--user", f"=={random.randint(1,5)}.{random.randint(0,20)}.{random.randint(0,10)}"])
                cmd = f"pip install {pkg}{flags}"
            elif action == "install -r":
                cmd = f"pip install -r {random.choice(['requirements.txt', 'requirements-dev.txt', 'requirements/prod.txt'])}"
            elif action == "uninstall":
                cmd = f"pip uninstall -y {random.choice(PIP_PACKAGES)}"
            elif action == "install --upgrade":
                cmd = f"pip install --upgrade {random.choice(PIP_PACKAGES)}"
            elif action == "install -e":
                cmd = "pip install -e ."
            else:
                cmd = f"pip {action}"

        elif pm == "cargo":
            action = random.choices(
                ["build", "run", "test", "add", "clippy", "fmt", "check",
                 "bench", "doc", "publish", "update", "tree", "install"],
                weights=[15, 12, 12, 15, 10, 8, 8, 3, 3, 2, 4, 4, 4],
            )[0]
            if action == "add":
                crate = random.choice(CARGO_CRATES)
                features = ""
                if random.random() < 0.3:
                    feat = random.choice(["derive", "full", "macros", "runtime", "json"])
                    features = f" --features {feat}"
                cmd = f"cargo add {crate}{features}"
            elif action == "build":
                flags = random.choice(["", "--release", "--target x86_64-unknown-linux-musl"])
                cmd = f"cargo build {flags}".strip()
            elif action == "run":
                flags = random.choice(["", "--release", "-- --help", f"--bin {random.choice(BASENAMES)}"])
                cmd = f"cargo run {flags}".strip()
            elif action == "test":
                flags = random.choice(["", "-- --nocapture", f"-- {random.choice(BASENAMES)}", "--release"])
                cmd = f"cargo test {flags}".strip()
            elif action == "install":
                tool = random.choice(["cargo-watch", "cargo-edit", "cargo-expand",
                                       "cargo-audit", "ripgrep", "fd-find", "bat",
                                       "tokei", "hyperfine", "just"])
                cmd = f"cargo install {tool}"
            else:
                cmd = f"cargo {action}"

        elif pm == "apt":
            action = random.choice(["install", "update", "upgrade", "search",
                                     "remove", "purge", "autoremove", "list --installed"])
            if action == "install":
                pkg = random.choice([
                    "build-essential", "curl", "wget", "git", "vim", "tmux",
                    "htop", "tree", "jq", "unzip", "nginx", "postgresql",
                    "redis-server", "docker.io", "python3-pip", "nodejs",
                    "libssl-dev", "pkg-config", "cmake", "clang",
                ])
                cmd = f"sudo apt install -y {pkg}"
            elif action == "search":
                cmd = f"apt search {random.choice(['python', 'node', 'docker', 'lib', 'dev'])}"
            elif action == "remove":
                cmd = f"sudo apt remove {random.choice(['vim', 'nano', 'nginx', 'apache2'])}"
            else:
                cmd = f"sudo apt {action}"

        elif pm == "pacman":
            action = random.choice(["-S", "-Syu", "-Ss", "-R", "-Q", "-Qi", "-Ql"])
            if action == "-S":
                pkg = random.choice(["base-devel", "git", "vim", "tmux", "docker",
                                      "python", "nodejs", "go", "rust", "nginx"])
                cmd = f"sudo pacman -S --noconfirm {pkg}"
            elif action == "-Ss":
                cmd = f"pacman -Ss {random.choice(['python', 'node', 'docker', 'lib'])}"
            elif action == "-R":
                cmd = f"sudo pacman -R {random.choice(['vim', 'nano', 'nginx'])}"
            else:
                cmd = f"pacman {action}"

        elif pm == "dnf":
            action = random.choice(["install", "update", "search", "remove", "list installed"])
            if action == "install":
                pkg = random.choice(["gcc", "make", "curl", "git", "vim", "docker",
                                      "python3", "nodejs", "nginx", "redis"])
                cmd = f"sudo dnf install -y {pkg}"
            elif action == "search":
                cmd = f"dnf search {random.choice(['python', 'node', 'docker'])}"
            else:
                cmd = f"sudo dnf {action}"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_docker(n):
    """Generate Docker commands."""
    count = 0
    while count < n:
        sub = random.choices(
            ["run", "build", "exec", "compose", "ps", "images", "logs",
             "pull", "push", "stop", "rm", "rmi", "inspect", "network",
             "volume", "system"],
            weights=[15, 12, 10, 20, 5, 4, 8, 5, 3, 5, 4, 3, 3, 3, 3, 2],
        )[0]

        if sub == "run":
            image = random.choice(DOCKER_IMAGES)
            flags = []
            if random.random() < 0.7:
                flags.append("-d")
            if random.random() < 0.5:
                flags.append(f"--name {random.choice(BASENAMES)}")
            if random.random() < 0.6:
                p1, p2 = rand_port(), rand_port()
                flags.append(f"-p {p1}:{p2}")
            if random.random() < 0.3:
                flags.append(f"-v {rand_dir()}:/data")
            if random.random() < 0.3:
                flags.append(f"-e ENV={random.choice(['production', 'development', 'test'])}")
            if random.random() < 0.2:
                flags.append("--rm")
            if random.random() < 0.15:
                flags.append("--network host")
            cmd = f"docker run {' '.join(flags)} {image}".replace("  ", " ").strip()

        elif sub == "build":
            tag = f"{random.choice(BASENAMES)}:{random.choice(['latest', 'dev', 'v1', 'v2'])}"
            flags = [f"-t {tag}"]
            if random.random() < 0.3:
                flags.append(f"-f {random.choice(['Dockerfile', 'Dockerfile.dev', 'Dockerfile.prod'])}")
            if random.random() < 0.2:
                flags.append("--no-cache")
            if random.random() < 0.2:
                flags.append("--build-arg NODE_ENV=production")
            cmd = f"docker build {' '.join(flags)} ."

        elif sub == "exec":
            container = random.choice(BASENAMES)
            shell = random.choice(["/bin/bash", "/bin/sh", "bash", "sh"])
            flags = random.choice(["-it", "-i", "-t"])
            if random.random() < 0.5:
                cmd = f"docker exec {flags} {container} {shell}"
            else:
                inner_cmd = random.choice([
                    "cat /etc/os-release", "env", "ls -la", "ps aux",
                    "whoami", "hostname", "df -h", "free -m",
                ])
                cmd = f"docker exec {container} {inner_cmd}"

        elif sub == "compose":
            action = random.choice([
                "up -d", "up", "down", "logs", "logs -f", "ps",
                "build", "restart", "stop", "pull", "exec",
                "up --build -d", "down -v", "config",
            ])
            prefix = random.choice(["docker compose", "docker-compose"])
            if action == "exec":
                svc = random.choice(["web", "api", "db", "redis", "worker", "app", "nginx"])
                cmd = f"{prefix} exec {svc} {random.choice(['bash', 'sh'])}"
            elif action.startswith("logs"):
                svc = random.choice(["web", "api", "db", "redis", "worker", "app", ""])
                cmd = f"{prefix} {action} {svc}".strip()
            else:
                file_flag = ""
                if random.random() < 0.2:
                    file_flag = f"-f {random.choice(['docker-compose.yml', 'docker-compose.dev.yml', 'docker-compose.prod.yml'])} "
                cmd = f"{prefix} {file_flag}{action}".replace("  ", " ").strip()

        elif sub == "logs":
            container = random.choice(BASENAMES)
            flags = random.choice(["", "-f", "--tail 100", "-f --tail 50", "--since 1h"])
            cmd = f"docker logs {flags} {container}".replace("  ", " ").strip()

        elif sub == "ps":
            flags = random.choice(["", "-a", "-q", "--format '{{.Names}}'"])
            cmd = f"docker ps {flags}".strip()

        elif sub == "images":
            flags = random.choice(["", "-q", "--format '{{.Repository}}:{{.Tag}}'"])
            cmd = f"docker images {flags}".strip()

        elif sub == "pull":
            cmd = f"docker pull {random.choice(DOCKER_IMAGES)}"

        elif sub == "push":
            tag = f"registry.example.com/{random.choice(BASENAMES)}:latest"
            cmd = f"docker push {tag}"

        elif sub == "stop":
            cmd = f"docker stop {random.choice(BASENAMES)}"

        elif sub == "rm":
            flags = random.choice(["", "-f", "-v"])
            cmd = f"docker rm {flags} {random.choice(BASENAMES)}".replace("  ", " ").strip()

        elif sub == "rmi":
            cmd = f"docker rmi {random.choice(DOCKER_IMAGES)}"

        elif sub == "inspect":
            cmd = f"docker inspect {random.choice(BASENAMES)}"

        elif sub == "network":
            action = random.choice(["ls", "create mynet", "inspect bridge", "prune"])
            cmd = f"docker network {action}"

        elif sub == "volume":
            action = random.choice(["ls", f"create {random.choice(BASENAMES)}_data",
                                     "prune", f"inspect {random.choice(BASENAMES)}_data"])
            cmd = f"docker volume {action}"

        elif sub == "system":
            action = random.choice(["prune -f", "df", "info"])
            cmd = f"docker system {action}"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_ssh_network(n):
    """Generate SSH and network commands."""
    count = 0
    while count < n:
        tool = random.choices(
            ["ssh", "scp", "rsync", "curl", "wget", "ping", "netstat", "ss",
             "nmap", "dig", "nc", "traceroute", "ip"],
            weights=[15, 10, 10, 20, 8, 5, 5, 5, 4, 5, 4, 4, 5],
        )[0]

        if tool == "ssh":
            host = rand_host()
            flags = []
            if random.random() < 0.2:
                flags.append(f"-p {random.choice([22, 2222, 2200])}")
            if random.random() < 0.2:
                flags.append(f"-i ~/.ssh/{random.choice(['id_rsa', 'id_ed25519', 'deploy_key'])}")
            if random.random() < 0.15:
                flags.append("-A")
            if random.random() < 0.1:
                flags.append(f"-L {rand_port()}:localhost:{rand_port()}")
            if random.random() < 0.15:
                # Remote command
                remote_cmd = random.choice([
                    "'ls -la'", "'uptime'", "'df -h'", "'free -m'",
                    f"'systemctl status {random.choice(SERVICES)}'",
                    "'docker ps'", "'tail -f /var/log/syslog'",
                ])
                cmd = f"ssh {' '.join(flags)} {host} {remote_cmd}".replace("  ", " ").strip()
            else:
                cmd = f"ssh {' '.join(flags)} {host}".replace("  ", " ").strip()

        elif tool == "scp":
            host = rand_host()
            if random.random() < 0.5:
                # Upload
                cmd = f"scp {rand_path()} {host}:{rand_path()}"
            else:
                # Download
                cmd = f"scp {host}:{rand_path()} {rand_path()}"
            if random.random() < 0.3:
                cmd = cmd.replace("scp", "scp -r")

        elif tool == "rsync":
            host = rand_host()
            flags = random.choice(["-avz", "-av", "-avzP", "-az --delete",
                                    "-avz --exclude='node_modules'",
                                    "-avz --exclude='.git'"])
            if random.random() < 0.5:
                cmd = f"rsync {flags} {rand_dir()}/ {host}:{rand_dir()}/"
            else:
                cmd = f"rsync {flags} {host}:{rand_dir()}/ {rand_dir()}/"

        elif tool == "curl":
            url = random.choice(URLS)
            flags = []
            method = random.choices(
                ["GET", "POST", "PUT", "DELETE", "PATCH"],
                weights=[40, 25, 10, 10, 5],
            )[0]
            if method != "GET":
                flags.append(f"-X {method}")
            if random.random() < 0.4:
                flags.append("-s")
            if random.random() < 0.3:
                flags.append("-v")
            if random.random() < 0.3:
                flags.append("-H 'Content-Type: application/json'")
            if random.random() < 0.2:
                flags.append("-H 'Authorization: Bearer $TOKEN'")
            if method in ("POST", "PUT", "PATCH") and random.random() < 0.6:
                body = random.choice([
                    "-d '{\"key\": \"value\"}'",
                    "-d '{\"name\": \"test\", \"email\": \"test@example.com\"}'",
                    "-d @data.json",
                    "--data-raw '{\"query\": \"test\"}'",
                ])
                flags.append(body)
            if random.random() < 0.2:
                flags.append("-o output.json")
            if random.random() < 0.15:
                flags.append("-w '%{http_code}'")
            if random.random() < 0.1:
                flags.append("--connect-timeout 10")
            if random.random() < 0.1:
                flags.append("-L")  # follow redirects
            cmd = f"curl {' '.join(flags)} {url}".replace("  ", " ").strip()

        elif tool == "wget":
            url = random.choice(URLS)
            flags = random.choice(["", "-q", "-O output", "-c", "--no-check-certificate",
                                    "-r -l 1", "-P downloads/"])
            cmd = f"wget {flags} {url}".replace("  ", " ").strip()

        elif tool == "ping":
            host = f"{random.choice(HOSTNAMES)}.{random.choice(DOMAINS)}"
            flags = random.choice(["-c 4", "-c 3", "-c 10", "-c 1"])
            cmd = f"ping {flags} {host}"

        elif tool == "netstat":
            flags = random.choice(["-tlnp", "-tulnp", "-an", "-rn", "-s"])
            cmd = f"netstat {flags}"

        elif tool == "ss":
            flags = random.choice(["-tlnp", "-tulnp", "-s", "-a", "-lt"])
            cmd = f"ss {flags}"

        elif tool == "nmap":
            host = f"{random.choice(HOSTNAMES)}.{random.choice(DOMAINS)}"
            flags = random.choice(["-sV", "-sS", "-A", "-p 1-1000", "-Pn",
                                    f"-p {rand_port()}", "--top-ports 100"])
            cmd = f"nmap {flags} {host}"

        elif tool == "dig":
            domain = random.choice(DOMAINS)
            rtype = random.choice(["A", "AAAA", "MX", "NS", "TXT", "CNAME", "SOA"])
            flags = random.choice(["", "+short", "+trace", "@8.8.8.8"])
            cmd = f"dig {flags} {domain} {rtype}".replace("  ", " ").strip()

        elif tool == "nc":
            host = random.choice(HOSTNAMES)
            port = rand_port()
            flags = random.choice(["-zv", "-l -p", "-w 3"])
            cmd = f"nc {flags} {host} {port}"

        elif tool == "traceroute":
            host = random.choice(DOMAINS)
            cmd = f"traceroute {host}"

        elif tool == "ip":
            sub_cmd = random.choice(["addr", "addr show", "route", "route show",
                                      "link", "link show", "neigh", "-s link"])
            cmd = f"ip {sub_cmd}"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_find_grep_sed(n):
    """Generate find/grep/sed/awk commands."""
    count = 0
    while count < n:
        tool = random.choices(
            ["find", "grep", "sed", "awk", "xargs", "wc", "sort", "uniq", "cut", "tr"],
            weights=[25, 30, 15, 10, 5, 3, 4, 3, 3, 2],
        )[0]

        if tool == "find":
            base = random.choice([".", "./src", "./lib", "/var/log", "/tmp",
                                   "/home/user", "~/projects", rand_dir()])
            predicates = []
            if random.random() < 0.6:
                ext = random.choice(EXTS)
                predicates.append(f"-name '*{ext}'")
            elif random.random() < 0.5:
                name = random.choice(BASENAMES)
                predicates.append(f"-name '{name}*'")
            if random.random() < 0.4:
                predicates.append(random.choice(["-type f", "-type d"]))
            if random.random() < 0.2:
                predicates.append(f"-mtime -{rand_number(1, 30)}")
            if random.random() < 0.15:
                predicates.append(f"-size +{random.choice(['1M', '10M', '100M', '1G', '100k'])}")
            if random.random() < 0.2:
                predicates.append(f"-maxdepth {rand_number(1, 5)}")
            action = ""
            if random.random() < 0.2:
                action = random.choice([
                    "-exec rm {} \\;",
                    "-exec chmod 644 {} \\;",
                    "-exec grep -l 'TODO' {} \\;",
                    "-delete",
                    "| xargs wc -l",
                    "| head -20",
                    "| sort",
                ])
            if not predicates:
                predicates.append("-type f")
            cmd = f"find {base} {' '.join(predicates)} {action}".replace("  ", " ").strip()

        elif tool == "grep":
            pattern = random.choice(GREP_PATTERNS)
            flags = random.choice(["-rn", "-r", "-rni", "-rl", "-rn --include='*.py'",
                                    f"-rn --include='*{random.choice(EXTS)}'",
                                    "-rn -e", "-c", "-v", "-w", "-E"])
            target = random.choice([".", "./src", rand_path(), "/var/log/*.log", "/etc/"])
            if random.random() < 0.2:
                pipe = random.choice(["| head -20", "| wc -l", "| sort", "| less"])
                cmd = f"grep {flags} '{pattern}' {target} {pipe}"
            else:
                cmd = f"grep {flags} '{pattern}' {target}"

        elif tool == "sed":
            old_word = random.choice(["foo", "bar", "old", "debug", "http", "localhost",
                                       "password", "TODO", "v1", "dev", "test",
                                       "import", "require", "var", "let", "const"])
            new_word = random.choice(["baz", "qux", "new", "info", "https", "0.0.0.0",
                                       "***", "DONE", "v2", "prod", "staging",
                                       "from", "include", "const", "const", "let"])
            flags = random.choice(["", "-i", "-i.bak", "-n"])
            target = rand_path()
            pattern_type = random.choice(["substitute", "delete", "print", "insert"])
            if pattern_type == "substitute":
                g = "g" if random.random() < 0.6 else ""
                cmd = f"sed {flags} 's/{old_word}/{new_word}/{g}' {target}".replace("  ", " ").strip()
            elif pattern_type == "delete":
                line = rand_number(1, 50)
                cmd = f"sed {flags} '{line}d' {target}".replace("  ", " ").strip()
            elif pattern_type == "print":
                start, end = sorted([rand_number(1, 50), rand_number(1, 50)])
                cmd = f"sed -n '{start},{end}p' {target}"
            else:
                cmd = f"sed {flags} '1i\\# Header' {target}".replace("  ", " ").strip()

        elif tool == "awk":
            program = random.choice([
                "'{print $1}'", "'{print $1, $2}'", "'{print $NF}'",
                "'{print NR, $0}'", "'-F: {print $1}'", "'-F, {print $2}'",
                "'{sum += $1} END {print sum}'", "'{if ($1 > 100) print}'",
                "'/ERROR/ {print}'", "'{print NF}'",
                "'-F\"\\t\" {print $1}'",
                "'{arr[$1]++} END {for (k in arr) print k, arr[k]}'",
            ])
            target = random.choice([rand_path(), "/var/log/syslog", "/etc/passwd", "access.log"])
            if random.random() < 0.3:
                pipe_from = random.choice([
                    f"cat {target} | ", f"ps aux | ", "df -h | ", "ls -la | ",
                    "free -m | ", "netstat -tlnp | ",
                ])
                cmd = f"{pipe_from}awk {program}"
            else:
                cmd = f"awk {program} {target}"

        elif tool == "xargs":
            source = random.choice([
                f"find . -name '*{random.choice(EXTS)}'",
                f"grep -rl 'TODO' .",
                "cat files.txt",
                f"ls {rand_dir()}",
            ])
            action = random.choice([
                "rm", "wc -l", "head -1", f"grep -l '{random.choice(GREP_PATTERNS[:7])}'",
                "chmod 644", "file",
            ])
            flags = random.choice(["", "-I{}", "-n 1", "-P 4"])
            cmd = f"{source} | xargs {flags} {action}".replace("  ", " ").strip()

        elif tool == "wc":
            flags = random.choice(["-l", "-w", "-c", "-lw"])
            target = rand_path()
            if random.random() < 0.3:
                cmd = f"find . -name '*{random.choice(EXTS)}' | xargs wc {flags}"
            else:
                cmd = f"wc {flags} {target}"

        elif tool == "sort":
            flags = random.choice(["", "-n", "-r", "-nr", "-u", "-k2", "-t, -k2 -n"])
            target = rand_path()
            cmd = f"sort {flags} {target}".replace("  ", " ").strip()

        elif tool == "uniq":
            flags = random.choice(["", "-c", "-d", "-u"])
            cmd = f"sort {rand_path()} | uniq {flags}".strip()

        elif tool == "cut":
            flags = random.choice(["-d' ' -f1", "-d: -f1", "-d, -f2", "-f1-3",
                                    "-d'\\t' -f1,3", "-c1-20"])
            cmd = f"cut {flags} {rand_path()}"

        elif tool == "tr":
            transform = random.choice([
                "'a-z' 'A-Z'", "'A-Z' 'a-z'", "-d '\\n'", "-s ' '",
                "'\\t' ' '", "-d '\\r'", "':' '\\n'",
            ])
            cmd = f"cat {rand_path()} | tr {transform}"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_sysadmin(n):
    """Generate system administration commands."""
    count = 0
    while count < n:
        tool = random.choices(
            ["systemctl", "journalctl", "ps", "kill", "top", "htop",
             "df", "du", "free", "uptime", "uname", "lsblk", "mount",
             "crontab", "useradd", "usermod", "tail", "head", "less",
             "watch", "screen", "tmux", "env", "export", "alias"],
            weights=[15, 12, 10, 6, 4, 3,
                     5, 5, 4, 3, 2, 2, 2,
                     4, 3, 2, 5, 3, 2,
                     4, 3, 4, 2, 3, 2],
        )[0]

        if tool == "systemctl":
            action = random.choice(["start", "stop", "restart", "status",
                                     "enable", "disable", "is-active", "is-enabled",
                                     "daemon-reload", "list-units", "list-unit-files"])
            service = random.choice(SERVICES)
            if action in ("daemon-reload", "list-units", "list-unit-files"):
                cmd = f"sudo systemctl {action}"
            else:
                cmd = f"sudo systemctl {action} {service}"

        elif tool == "journalctl":
            flags = random.choice([
                f"-u {random.choice(SERVICES)}",
                f"-u {random.choice(SERVICES)} -f",
                f"-u {random.choice(SERVICES)} --since '1 hour ago'",
                f"-u {random.choice(SERVICES)} -n 100",
                "-xe", "--no-pager -n 50", "-b", "-k",
                f"-u {random.choice(SERVICES)} --since today",
            ])
            cmd = f"journalctl {flags}"

        elif tool == "ps":
            flags = random.choice(["aux", "ef", "aux --sort=-%mem", "aux --sort=-%cpu",
                                    f"aux | grep {random.choice(BASENAMES)}"])
            if "|" in flags:
                cmd = f"ps {flags}"
            else:
                cmd = f"ps {flags}"

        elif tool == "kill":
            variant = random.choice([
                f"-9 {random.randint(1000, 65000)}",
                f"-TERM {random.randint(1000, 65000)}",
                f"-HUP {random.randint(1000, 65000)}",
            ])
            if random.random() < 0.4:
                process = random.choice(["node", "python", "nginx", "redis", "java", "go"])
                cmd = f"pkill {random.choice(['-f', '-9', ''])} {process}".replace("  ", " ").strip()
            else:
                cmd = f"kill {variant}"

        elif tool == "top":
            flags = random.choice(["", "-bn1", f"-p {random.randint(1000,65000)}"])
            cmd = f"top {flags}".strip()

        elif tool == "htop":
            cmd = "htop"

        elif tool == "df":
            flags = random.choice(["-h", "-h .", "-hT", "-i"])
            cmd = f"df {flags}"

        elif tool == "du":
            flags = random.choice(["-sh", "-sh *", f"-sh {rand_dir()}", "-h --max-depth=1",
                                    "-sh * | sort -rh | head -10"])
            cmd = f"du {flags}"

        elif tool == "free":
            flags = random.choice(["-h", "-m", "-g", "-h -s 5"])
            cmd = f"free {flags}"

        elif tool == "uptime":
            cmd = "uptime"

        elif tool == "uname":
            flags = random.choice(["-a", "-r", "-m", "-s"])
            cmd = f"uname {flags}"

        elif tool == "lsblk":
            cmd = random.choice(["lsblk", "lsblk -f"])

        elif tool == "mount":
            cmd = random.choice(["mount", "mount | column -t",
                                  f"sudo mount /dev/sda1 /mnt"])

        elif tool == "crontab":
            flags = random.choice(["-l", "-e", "-r"])
            cmd = f"crontab {flags}"

        elif tool == "useradd":
            user = random.choice(["deploy", "app", "service", "backup", "monitor"])
            flags = random.choice(["-m", "-m -s /bin/bash", "-r -s /usr/sbin/nologin"])
            cmd = f"sudo useradd {flags} {user}"

        elif tool == "usermod":
            user = random.choice(USERS)
            flags = random.choice(["-aG docker", "-aG sudo", "-s /bin/bash",
                                    f"-aG {random.choice(['wheel', 'admin', 'www-data'])}"])
            cmd = f"sudo usermod {flags} {user}"

        elif tool == "tail":
            flags = random.choice(["-f", f"-n {rand_number(10, 100)}", "-f -n 50"])
            target = random.choice([
                rand_path(), "/var/log/syslog", "/var/log/nginx/access.log",
                "/var/log/nginx/error.log", "/var/log/auth.log",
            ])
            cmd = f"tail {flags} {target}"

        elif tool == "head":
            flags = f"-n {rand_number(5, 50)}"
            cmd = f"head {flags} {rand_path()}"

        elif tool == "less":
            cmd = f"less {rand_path()}"

        elif tool == "watch":
            inner = random.choice([
                "'df -h'", "'free -m'", "'docker ps'", "'kubectl get pods'",
                f"'ls -la {rand_dir()}'", "'netstat -tlnp'",
            ])
            flags = random.choice(["-n 2", "-n 5", "-n 1", "-d"])
            cmd = f"watch {flags} {inner}"

        elif tool == "screen":
            action = random.choice([
                "-ls", f"-S {random.choice(BASENAMES)}", "-r", "-d -r",
                f"-S {random.choice(BASENAMES)} -dm bash -c '{random.choice(BASENAMES)}'",
            ])
            cmd = f"screen {action}"

        elif tool == "tmux":
            action = random.choice([
                "new -s work", "attach -t work", "ls", "kill-session -t work",
                f"new -s {random.choice(BASENAMES)}", "detach",
                "split-window -h", "split-window -v", "select-pane -t 0",
            ])
            cmd = f"tmux {action}"

        elif tool == "env":
            cmd = random.choice(["env", "env | grep PATH", "env | grep HOME",
                                  "printenv", f"echo ${random.choice(['HOME', 'PATH', 'USER', 'SHELL'])}"])

        elif tool == "export":
            var = random.choice(["PATH", "NODE_ENV", "GOPATH", "RUST_LOG",
                                  "DATABASE_URL", "REDIS_URL", "PORT", "DEBUG"])
            val = random.choice(["production", "development", "test", "1", "true",
                                  "/usr/local/bin:$PATH", "localhost:5432",
                                  "info", "8080", "0.0.0.0"])
            cmd = f"export {var}={val}"

        elif tool == "alias":
            name = random.choice(["ll", "la", "g", "gs", "gp", "dc", "k", "py", "tf"])
            value = random.choice([
                "ls -la", "ls -la", "git", "git status", "git push",
                "docker compose", "kubectl", "python3", "terraform",
            ])
            cmd = f"alias {name}='{value}'"
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_build_tools(n):
    """Generate build tool commands."""
    count = 0
    while count < n:
        tool = random.choices(
            ["make", "cmake", "gcc", "clang", "zig", "go", "python", "node"],
            weights=[20, 10, 12, 10, 12, 12, 12, 12],
        )[0]

        if tool == "make":
            target = random.choice(MAKE_TARGETS)
            flags = random.choice(["", "-j$(nproc)", "-j4", "-j8", "V=1", "-B", "-n"])
            cmd = f"make {flags} {target}".replace("  ", " ").strip()

        elif tool == "cmake":
            action = random.choice([
                "-B build", "-B build -DCMAKE_BUILD_TYPE=Release",
                "-B build -DCMAKE_BUILD_TYPE=Debug",
                "--build build", "--build build --parallel",
                "--build build --target install",
                "-B build -G Ninja", "-B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
            ])
            cmd = f"cmake {action}"

        elif tool in ("gcc", "clang"):
            src = f"{random.choice(BASENAMES)}.c"
            out = random.choice(["a.out", "main", random.choice(BASENAMES)])
            flags = random.choice([
                f"-o {out}", f"-o {out} -Wall -Wextra",
                f"-o {out} -O2", f"-o {out} -g",
                f"-o {out} -std=c11 -Wall -Wextra -pedantic",
                f"-o {out} -O3 -march=native",
                f"-o {out} -fsanitize=address,undefined",
                "-c", f"-S -O2",
                f"-o {out} -lpthread -lm",
                f"-shared -fPIC -o lib{out}.so",
            ])
            cmd = f"{tool} {flags} {src}"

        elif tool == "zig":
            action = random.choices(
                ["build", "build run", "build test", "test", "run", "fmt", "zen",
                 "build-exe", "build-lib", "translate-c"],
                weights=[20, 15, 15, 10, 10, 8, 2, 5, 5, 5],
            )[0]
            if action == "build":
                flags = random.choice(["", "-Doptimize=ReleaseFast", "-Doptimize=Debug",
                                        "-Doptimize=ReleaseSafe", "--summary all"])
                cmd = f"zig build {flags}".strip()
            elif action == "build run":
                flags = random.choice(["", "-- --help", "-- --verbose"])
                cmd = f"zig build run {flags}".strip()
            elif action == "build test":
                cmd = "zig build test"
            elif action in ("test", "run"):
                src = f"src/{random.choice(BASENAMES)}.zig"
                cmd = f"zig {action} {src}"
            elif action == "fmt":
                target = random.choice(["src/", f"src/{random.choice(BASENAMES)}.zig", "."])
                cmd = f"zig fmt {target}"
            elif action == "build-exe":
                cmd = f"zig build-exe src/{random.choice(BASENAMES)}.zig"
            elif action == "translate-c":
                cmd = f"zig translate-c {random.choice(BASENAMES)}.h"
            else:
                cmd = f"zig {action}"

        elif tool == "go":
            action = random.choices(
                ["build", "run", "test", "fmt", "vet", "mod tidy", "mod init",
                 "get", "install", "generate", "clean"],
                weights=[15, 12, 15, 8, 5, 8, 4, 10, 5, 5, 3],
            )[0]
            if action == "run":
                target = random.choice([".", "./cmd/server", f"./cmd/{random.choice(BASENAMES)}", "main.go"])
                cmd = f"go run {target}"
            elif action == "build":
                flags = random.choice(["", "-o bin/app", "-race", "-v",
                                        "-ldflags '-s -w'", "-o bin/server ./cmd/server"])
                cmd = f"go build {flags} .".replace("  ", " ").strip()
            elif action == "test":
                flags = random.choice(["./...", "-v ./...", "-race ./...",
                                        "-cover ./...", f"-run Test{random.choice(BASENAMES).title()} ./..."])
                cmd = f"go test {flags}"
            elif action == "get":
                mod = random.choice([
                    "github.com/gin-gonic/gin", "github.com/gorilla/mux",
                    "github.com/spf13/cobra", "github.com/spf13/viper",
                    "gorm.io/gorm", "github.com/redis/go-redis/v9",
                    "go.uber.org/zap", "github.com/stretchr/testify",
                ])
                cmd = f"go get {mod}"
            elif action == "mod init":
                cmd = f"go mod init github.com/user/{random.choice(BASENAMES)}"
            else:
                cmd = f"go {action}"

        elif tool == "python":
            action = random.choice([
                f"python3 {random.choice(BASENAMES)}.py",
                f"python3 -m pytest",
                f"python3 -m pytest -v",
                f"python3 -m pytest --cov=src",
                f"python3 -m black .",
                f"python3 -m ruff check .",
                f"python3 -m ruff check --fix .",
                f"python3 -m mypy src/",
                f"python3 -m uvicorn app:app --reload",
                f"python3 -m gunicorn app:app -w 4",
                f"python3 -m flask run --debug",
                f"python3 manage.py runserver",
                f"python3 manage.py migrate",
                f"python3 manage.py makemigrations",
                f"python3 manage.py createsuperuser",
                f"python3 manage.py shell",
                f"python3 -c 'import sys; print(sys.version)'",
                "python3 -m venv venv",
                "source venv/bin/activate",
                "python3 -m pip install --upgrade pip",
            ])
            cmd = action

        elif tool == "node":
            action = random.choice([
                f"node {random.choice(BASENAMES)}.js",
                f"node --inspect {random.choice(BASENAMES)}.js",
                "node -e 'console.log(process.version)'",
                "node --max-old-space-size=4096 build.js",
                f"npx ts-node {random.choice(BASENAMES)}.ts",
                "npx tsc --noEmit",
                "npx tsc",
                "npx eslint .",
                "npx eslint --fix .",
                "npx prettier --write .",
                "npx jest",
                "npx jest --coverage",
                "npx vitest",
                "npx vitest run",
                "npx prisma migrate dev",
                "npx prisma generate",
                "npx prisma db seed",
                "npx next dev",
                "npx next build",
            ])
            cmd = action
        else:
            continue

        emit(cmd)
        count += 1
    return count


def gen_prefix_completions(n):
    """Generate prefix completion examples from various command patterns."""
    count = 0
    generators = [
        lambda: f"git commit -m \"{rand_commit_msg()}\"",
        lambda: f"docker run -d -p {rand_port()}:{rand_port()} {random.choice(DOCKER_IMAGES)}",
        lambda: f"ssh {rand_host()}",
        lambda: f"find . -name '*{random.choice(EXTS)}' -type f",
        lambda: f"grep -rn '{random.choice(GREP_PATTERNS[:10])}' {random.choice(['./src', '.', './lib'])}",
        lambda: f"curl -s -H 'Authorization: Bearer $TOKEN' {random.choice(URLS)}",
        lambda: f"rsync -avz {rand_dir()}/ {rand_host()}:{rand_dir()}/",
        lambda: f"tar -czf {random.choice(BASENAMES)}.tar.gz {rand_dir()}",
        lambda: f"sed -i 's/old/new/g' {rand_path()}",
        lambda: f"awk '{{print $1}}' {rand_path()}",
        lambda: f"pip install {random.choice(PIP_PACKAGES)}",
        lambda: f"npm install {random.choice(NPM_PACKAGES)}",
        lambda: f"cargo add {random.choice(CARGO_CRATES)}",
        lambda: f"sudo systemctl restart {random.choice(SERVICES)}",
        lambda: f"journalctl -u {random.choice(SERVICES)} -f",
        lambda: f"docker compose up -d",
        lambda: f"kubectl get pods -n {random.choice(['default', 'kube-system', 'monitoring', 'production'])}",
        lambda: f"scp {rand_path()} {rand_host()}:{rand_path()}",
        lambda: f"chmod {random.choice(PERMISSIONS)} {rand_path()}",
        lambda: f"make -j$(nproc) {random.choice(MAKE_TARGETS)}",
        lambda: f"zig build -Doptimize=ReleaseFast",
        lambda: f"go test -v ./...",
        lambda: f"python3 -m pytest --cov=src -v",
        lambda: f"git log --oneline --graph -n {rand_number(10, 30)}",
        lambda: f"git rebase -i HEAD~{rand_number(2, 10)}",
        lambda: f"cp -r {rand_dir()} {rand_dir()}",
        lambda: f"mv {rand_path()} {rand_dir()}/",
        lambda: f"du -sh * | sort -rh | head -10",
        lambda: f"watch -n 2 'docker ps'",
        lambda: f"tail -f /var/log/{random.choice(['syslog', 'auth.log', 'nginx/access.log'])}",
    ]

    while count < n:
        gen = random.choice(generators)
        cmd = gen()
        tokens = cmd.split()
        if len(tokens) < 2:
            continue
        # Pick a random prefix split point
        split = random.randint(1, max(1, len(tokens) - 1))
        prefix = " ".join(tokens[:split])
        emit(f"$ {prefix}")
        count += 1
    return count


def gen_intent_command(n):
    """Generate intent-to-command training pairs."""
    count = 0

    INTENT_TEMPLATES = [
        ("find all {ext} files modified in the last {days} days",
         "find . -name '*{ext}' -mtime -{days}"),
        ("list all files in {dir} sorted by size",
         "ls -lhS {dir}"),
        ("count lines of code in all {ext} files",
         "find . -name '*{ext}' | xargs wc -l"),
        ("search for {pattern} in all {ext} files",
         "grep -rn '{pattern}' --include='*{ext}' ."),
        ("show disk usage of current directory",
         "du -sh ."),
        ("show free memory",
         "free -h"),
        ("kill process listening on port {port}",
         "kill $(lsof -t -i:{port})"),
        ("find largest files in {dir}",
         "find {dir} -type f -exec du -h {{}} + | sort -rh | head -20"),
        ("show git log with graph",
         "git log --oneline --graph --all"),
        ("create a new git branch called {branch}",
         "git checkout -b {branch}"),
        ("undo the last git commit but keep changes",
         "git reset --soft HEAD~1"),
        ("show differences between current branch and {branch}",
         "git diff {branch}...HEAD"),
        ("compress {dir} into a tar.gz file",
         "tar -czf {dir}.tar.gz {dir}"),
        ("extract a tar.gz archive",
         "tar -xzf archive.tar.gz"),
        ("show all running docker containers",
         "docker ps"),
        ("stop all running docker containers",
         "docker stop $(docker ps -q)"),
        ("remove all stopped docker containers",
         "docker container prune -f"),
        ("show docker container logs for {service}",
         "docker logs -f {service}"),
        ("connect to {host} via SSH",
         "ssh {host}"),
        ("copy {file} to remote server {host}",
         "scp {file} {host}:{file}"),
        ("sync {dir} to remote server {host}",
         "rsync -avz {dir}/ {host}:{dir}/"),
        ("download a file from {url}",
         "curl -LO {url}"),
        ("make an HTTP POST request with JSON body",
         "curl -X POST -H 'Content-Type: application/json' -d '{{\"key\": \"value\"}}' {url}"),
        ("check if a website is up",
         "curl -sI {url} | head -1"),
        ("show all open network ports",
         "ss -tlnp"),
        ("restart {service} service",
         "sudo systemctl restart {service}"),
        ("check status of {service}",
         "sudo systemctl status {service}"),
        ("view {service} logs in real time",
         "journalctl -u {service} -f"),
        ("find and delete all {ext} files",
         "find . -name '*{ext}' -delete"),
        ("replace {old} with {new} in all {ext} files",
         "find . -name '*{ext}' -exec sed -i 's/{old}/{new}/g' {{}} +"),
        ("show environment variables",
         "env"),
        ("add {user} to the docker group",
         "sudo usermod -aG docker {user}"),
        ("show current working directory",
         "pwd"),
        ("show file permissions for {file}",
         "ls -la {file}"),
        ("make {file} executable",
         "chmod +x {file}"),
        ("show system uptime",
         "uptime"),
        ("show kernel version",
         "uname -r"),
        ("list all installed packages",
         "dpkg --list"),
        ("install {package} package",
         "sudo apt install -y {package}"),
        ("update all system packages",
         "sudo apt update && sudo apt upgrade -y"),
        ("show top memory consuming processes",
         "ps aux --sort=-%mem | head -20"),
        ("show top CPU consuming processes",
         "ps aux --sort=-%cpu | head -20"),
        ("watch directory for changes",
         "watch -n 1 ls -la {dir}"),
        ("create a Python virtual environment",
         "python3 -m venv venv && source venv/bin/activate"),
        ("run Python tests with coverage",
         "python3 -m pytest --cov=src -v"),
        ("install npm dependencies",
         "npm install"),
        ("start development server",
         "npm run dev"),
        ("build the project",
         "npm run build"),
        ("run cargo tests",
         "cargo test"),
        ("format Rust code",
         "cargo fmt"),
        ("check Rust code for issues",
         "cargo clippy"),
        ("build Zig project in release mode",
         "zig build -Doptimize=ReleaseFast"),
        ("run Go tests",
         "go test -v ./..."),
        ("build Go project",
         "go build -o bin/app ."),
        ("show git status in short format",
         "git status -s"),
        ("stash current changes with a message",
         "git stash push -m 'work in progress'"),
        ("apply the last stash",
         "git stash pop"),
        ("show number of lines changed per file in git",
         "git diff --stat"),
        ("create a git tag for version {version}",
         "git tag -a {version} -m 'Release {version}'"),
        ("push all tags to remote",
         "git push --tags"),
        ("revert the last commit",
         "git revert HEAD"),
        ("show who last modified each line of {file}",
         "git blame {file}"),
        ("find files larger than {size}",
         "find . -size +{size} -type f"),
        ("show listening ports and their processes",
         "ss -tlnp"),
        ("test DNS resolution for {domain}",
         "dig {domain} +short"),
        ("check SSL certificate for {domain}",
         "openssl s_client -connect {domain}:443 -servername {domain}"),
        ("generate SSH key pair",
         "ssh-keygen -t ed25519 -C 'user@example.com'"),
        ("show all cron jobs",
         "crontab -l"),
        ("monitor system resources in real time",
         "htop"),
        ("show mounted filesystems",
         "df -hT"),
        ("find duplicate files",
         "find . -type f -exec md5sum {{}} + | sort | uniq -d -w32"),
        ("count files in directory",
         "find {dir} -type f | wc -l"),
        ("show last {n} lines of {file}",
         "tail -n {n} {file}"),
        ("follow {file} for new content",
         "tail -f {file}"),
        ("remove all node_modules directories",
         "find . -name 'node_modules' -type d -prune -exec rm -rf {{}} +"),
        ("show all processes matching {pattern}",
         "pgrep -af {pattern}"),
    ]

    fill_values = {
        "ext": EXTS,
        "days": [str(i) for i in range(1, 31)],
        "dir": DIRS,
        "pattern": GREP_PATTERNS[:10],
        "port": [str(p) for p in [3000, 5432, 8080, 8000, 6379, 27017, 9090, 443, 80]],
        "branch": BRANCH_NAMES,
        "host": None,  # special
        "file": None,  # special
        "service": SERVICES,
        "url": URLS,
        "old": ["foo", "bar", "old", "debug", "http", "TODO", "v1"],
        "new": ["baz", "qux", "new", "info", "https", "DONE", "v2"],
        "user": USERS,
        "package": ["curl", "git", "vim", "tmux", "htop", "docker.io", "nginx",
                     "build-essential", "python3-pip", "nodejs"],
        "version": [f"v{random.randint(0,5)}.{random.randint(0,20)}.{random.randint(0,10)}" for _ in range(20)],
        "size": ["10M", "100M", "1G", "500M", "50M"],
        "n": [str(i) for i in [10, 20, 50, 100, 200, 500]],
        "domain": DOMAINS,
    }

    while count < n:
        intent_tmpl, cmd_tmpl = random.choice(INTENT_TEMPLATES)

        # Find placeholders
        import re
        placeholders = re.findall(r'\{(\w+)\}', intent_tmpl)

        fills = {}
        for ph in set(placeholders):
            if ph == "host":
                fills[ph] = rand_host()
            elif ph == "file":
                fills[ph] = rand_path()
            elif ph in fill_values and fill_values[ph] is not None:
                fills[ph] = random.choice(fill_values[ph])
            else:
                fills[ph] = "example"

        try:
            intent = intent_tmpl.format(**fills)
            command = cmd_tmpl.format(**fills)
        except (KeyError, IndexError):
            continue

        text = f"Translate this intent to a shell command. Reply with ONLY the command.\nIntent: {intent}\n$ {command}"
        emit(text)
        count += 1

    return count


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    random.seed(42)  # Reproducible

    total = 0

    sys.stderr.write("Generating synthetic shell training data...\n")

    sys.stderr.write("  File operations (50K)...\n")
    total += gen_file_ops(50000)

    sys.stderr.write("  Git commands (30K)...\n")
    total += gen_git(30000)

    sys.stderr.write("  Package managers (20K)...\n")
    total += gen_package_managers(20000)

    sys.stderr.write("  Docker/container (10K)...\n")
    total += gen_docker(10000)

    sys.stderr.write("  SSH/network (10K)...\n")
    total += gen_ssh_network(10000)

    sys.stderr.write("  Find/grep/sed/awk (15K)...\n")
    total += gen_find_grep_sed(15000)

    sys.stderr.write("  System admin (10K)...\n")
    total += gen_sysadmin(10000)

    sys.stderr.write("  Build tools (10K)...\n")
    total += gen_build_tools(10000)

    sys.stderr.write("  Prefix completions (100K)...\n")
    total += gen_prefix_completions(100000)

    sys.stderr.write("  Intent → command (20K)...\n")
    total += gen_intent_command(20000)

    sys.stderr.write(f"\nTotal examples generated: {total}\n")


if __name__ == "__main__":
    main()
