# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Public repository holding the Business Central AL extension that Hevo's Microsoft 365 Business
Central connector reads from. See `README.md` for what it exposes and how to install it.

## Layout

- `src/HevoBusinessCentralConnector.al` - the whole extension in one file
- `app.json` - extension manifest (version, ID range 86500–86649, platform/runtime)

## Source of truth

The AL file is developed in the private `microsoft-365-business-central-connector` repo
(`al-extension/`), where the data pages, `HEVO READ` and delete subscribers are generated from a
contract by `tools/generate_pages.py`. Don't hand-edit the generated region here; change it there
and copy the file over.

## Notes

- This repo is public: no internal URLs, credentials or customer data.
- No CI runs from this repo.
