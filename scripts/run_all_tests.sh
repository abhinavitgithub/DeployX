#!/usr/bin/env bash
set -e

cd /home/abhinav2004/projects/deployx
source .venv/bin/activate

echo "=========================================="
echo " 1. PYTEST TEST SUITES (Backend & Frontend)"
echo "=========================================="
pytest -v backend/tests/ tests/

echo ""
echo "=========================================="
echo " 2. RUFF CODE QUALITY & LINTING"
echo "=========================================="
ruff check backend/ tests/ frontend/

echo ""
echo "=========================================="
echo " 3. PROMETHEUS PARSER UNIT TEST (Node.js)"
echo "=========================================="
/mnt/c/Program\ Files/nodejs/node.exe frontend/test_api_parser.js

echo ""
echo "=========================================="
echo " 4. SIDEBAR NAVIGATION UNIT TEST (Node.js)"
echo "=========================================="
/mnt/c/Program\ Files/nodejs/node.exe frontend/test_navigation.js

echo ""
echo "=========================================="
echo " 5. LIVE FRONTEND E2E HARNESS (Python)"
echo "=========================================="
python3 frontend/verify_frontend_e2e.py

echo ""
echo "=========================================="
echo " ALL TESTS COMPLETED SUCCESSFULLY!"
echo "=========================================="
