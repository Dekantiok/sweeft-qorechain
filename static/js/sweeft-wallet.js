/**
 * Sweeft wallet — session login, QoreX (native + EVM), and transaction helpers.
 *
 * Wallets are discovered properly:
 *  - QoreX native lane:  window.qorex.native  (ML-DSA-87 posting-quantum signing)
 *  - EVM wallets:        EIP-6963 announcements — QoreX's own EVM provider is
 *                        announced this way and never writes window.ethereum
 *  - window.ethereum     kept as a legacy fallback for MetaMask-style wallets
 *
 * Login is a server session: the wallet signs a one-time challenge, the server
 * verifies (QoreX PQ signatures against the key registered on chain) and the
 * page reloads as connected.
 */
(function () {
    "use strict";

    const DIANA = {
        chainId: "0x2648", // 9800
        chainName: "QoreChain Diana Testnet",
        nativeCurrency: { name: "QOR", symbol: "QOR", decimals: 18 },
        rpcUrls: ["https://evm-testnet.qore.host"],
        blockExplorerUrls: ["https://explore.qore.network"],
    };

    const QOREX_RDNS = "network.qore.qorex";
    const STORAGE_KEY = "sweeft.evmProvider";

    const evmProviders = []; // EIP-6963 announcements + legacy fallback
    const state = { address: null, chainId: null };

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function csrf() {
        const meta = document.querySelector('meta[name="csrf-token"]');
        return meta ? meta.content : "";
    }

    function qorexNative() {
        return window.qorex && window.qorex.native ? window.qorex.native : null;
    }

    async function jsonPost(url, body) {
        const response = await fetch(url, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-CSRFToken": csrf() },
            body: JSON.stringify(body || {}),
        });
        const text = await response.text();
        try {
            return text ? JSON.parse(text) : {};
        } catch (e) {
            throw new Error(`${url} → HTTP ${response.status}`);
        }
    }

    function shortAddress(address) {
        return address ? address.slice(0, 6) + "…" + address.slice(-4) : "";
    }

    /** Ask QoreX to run on Testnet — the wallet has no programmatic switch, so
     *  surface precise guidance for the most common mismatch. */
    function qorexNetworkHint(errorMessage) {
        if (/does not match the active network/i.test(errorMessage || "")) {
            return (
                "Your QoreX wallet is on a different network (likely mainnet / Vladi). " +
                "Open the QoreX app, switch the network selector to Testnet (Diana), " +
                "then press Connect again."
            );
        }
        return "";
    }

    // ------------------------------------------------------------------
    // EIP-6963 discovery
    // ------------------------------------------------------------------

    function registerProvider(detail) {
        if (!detail || !detail.info || !detail.provider) return;
        const { uuid } = detail.info;
        if (evmProviders.some((entry) => entry.info.uuid === uuid)) return;
        evmProviders.push(detail);
        renderOptionsIfOpen();
    }

    window.addEventListener("eip6963:announceProvider", (event) => registerProvider(event.detail));

    function discoverEvmProviders(timeoutMs = 350) {
        return new Promise((resolve) => {
            try {
                window.dispatchEvent(new Event("eip6963:requestProvider"));
            } catch (e) {
                /* older browsers */
            }
            setTimeout(() => {
                // Legacy fallback: a plain window.ethereum that did not announce.
                if (window.ethereum && !evmProviders.some((entry) => entry.provider === window.ethereum)) {
                    evmProviders.push({
                        info: { uuid: "legacy-window-ethereum", name: "Browser wallet (window.ethereum)", rdns: "legacy.ethereum" },
                        provider: window.ethereum,
                    });
                }
                resolve(evmProviders);
            }, timeoutMs);
        });
    }

    function selectedEvmProvider() {
        const wanted = localStorage.getItem(STORAGE_KEY);
        if (wanted) {
            const match = evmProviders.find(
                (entry) => entry.info.rdns === wanted || entry.info.uuid === wanted
            );
            if (match) return match.provider;
        }
        return evmProviders.length ? evmProviders[0].provider : null;
    }

    // ------------------------------------------------------------------
    // Modal
    // ------------------------------------------------------------------

    function modal() {
        let el = document.getElementById("wallet-modal");
        if (el) return el;
        el = document.createElement("div");
        el.id = "wallet-modal";
        el.style.cssText =
            "position:fixed;inset:0;z-index:100;display:none;align-items:center;justify-content:center;" +
            "background:rgba(2,6,23,0.72);backdrop-filter:blur(4px)";
        el.innerHTML =
            '<div style="width:min(28rem,92vw);background:#0f172a;border:1px solid #1e293b;border-radius:16px;padding:20px">' +
            '<div style="display:flex;justify-content:space-between;align-items:center">' +
            '<div style="font-weight:700;color:#e2e8f0">Connect a wallet</div>' +
            '<button id="wallet-modal-close" style="color:#64748b;font-size:18px;line-height:1">×</button>' +
            "</div>" +
            '<div id="wallet-modal-body" style="margin-top:14px"></div>' +
            '<div id="wallet-modal-status" style="margin-top:12px;font-size:12px;line-height:1.6;color:#94a3b8"></div>' +
            "</div>";
        document.body.appendChild(el);
        el.addEventListener("click", (event) => {
            if (event.target === el) closeModal();
        });
        el.querySelector("#wallet-modal-close").addEventListener("click", closeModal);
        return el;
    }

    function optionButton(id, badge, title, subtitle, enabled) {
        return (
            `<button id="${id}" ${enabled ? "" : "disabled"} style="width:100%;text-align:left;display:flex;` +
            "gap:12px;align-items:center;border:1px solid #1e293b;border-radius:12px;padding:12px;margin-bottom:10px;" +
            (enabled ? "cursor:pointer;background:#0b1220" : "cursor:not-allowed;opacity:0.5;background:#0b1220") +
            '">' +
            `<div style="width:36px;height:36px;border-radius:10px;background:#134e4a;color:#5eead4;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:13px">${badge}</div>` +
            `<div style="min-width:0"><div style="color:#e2e8f0;font-weight:600;font-size:14px">${title}</div>` +
            `<div style="color:#64748b;font-size:12px">${subtitle}</div></div>` +
            "</button>"
        );
    }

    async function renderOptions() {
        await discoverEvmProviders();
        const body = modal().querySelector("#wallet-modal-body");
        const native = qorexNative();
        const hasNative = !!native;

        const capabilities = (native && native.capabilities) || [];
        const nativeSigningOk = hasNative && capabilities.includes("signArbitrary");
        const nativeHint = !hasNative
            ? "not detected in this browser"
            : !nativeSigningOk
              ? "detected — this build does not announce signArbitrary; update QoreX"
              : "ML-DSA-87 post-quantum login and signing";

        let html = optionButton("wallet-pick-qorex", "Q", "QoreX", nativeHint, hasNative && nativeSigningOk);

        for (const entry of evmProviders) {
            const isQorexEvm = entry.info.rdns === QOREX_RDNS;
            const id = "wallet-pick-evm-" + entry.info.uuid.replace(/[^a-zA-Z0-9-]/g, "");
            html += optionButton(
                id,
                isQorexEvm ? "Q" : "E",
                entry.info.name + (isQorexEvm ? " (EVM lane)" : ""),
                "classical signing — buy, disputes, voting",
                true
            );
        }

        if (!hasNative && !evmProviders.length) {
            html +=
                '<p style="color:#94a3b8;font-size:12px;line-height:1.7">No wallet detected in this browser. ' +
                'Install the <a style="color:#5eead4" href="https://qorechain.io/qorex" target="_blank">QoreX wallet</a> ' +
                "(recommended — post-quantum signing) or any EVM wallet, then reload.</p>";
        }

        body.innerHTML = html;
        if (hasNative && nativeSigningOk) {
            document.getElementById("wallet-pick-qorex").addEventListener("click", connectQorex);
        }
        for (const entry of evmProviders) {
            const id = "wallet-pick-evm-" + entry.info.uuid.replace(/[^a-zA-Z0-9-]/g, "");
            const button = document.getElementById(id);
            if (button) button.addEventListener("click", () => connectEvm(entry));
        }
    }

    let optionsOpen = false;
    function renderOptionsIfOpen() {
        if (optionsOpen) renderOptions().catch(() => {});
    }

    function status(html) {
        const el = modal().querySelector("#wallet-modal-status");
        if (el) el.innerHTML = html || "";
    }

    function openModal() {
        optionsOpen = true;
        modal().style.display = "flex";
        status("");
        renderOptions().catch((err) => status(String(err)));
    }

    function closeModal() {
        optionsOpen = false;
        const el = document.getElementById("wallet-modal");
        if (el) el.style.display = "none";
    }

    // ------------------------------------------------------------------
    // Connect flows
    // ------------------------------------------------------------------

    async function connectQorex() {
        const native = qorexNative();
        if (!native) return;
        try {
            status("Waiting for QoreX…");
            await native.enable("qorechain-diana");
            const { bech32Address } = await native.getKey("qorechain-diana");

            status("Approve the login message in QoreX…");
            const challenge = await fetch(
                `/api/wallet/challenge/?address=${encodeURIComponent(bech32Address)}`,
                { headers: { Accept: "application/json" } }
            ).then((r) => r.json());

            const signature = await native.signArbitrary("qorechain-diana", bech32Address, challenge.message);
            const pqB64 = signature && signature.pq && signature.pq.signature;
            if (!pqB64) throw new Error("QoreX returned no ML-DSA-87 signature part");

            status("Verifying against your registered post-quantum key…");
            const result = await jsonPost("/api/wallet/verify/", {
                method: "qorex",
                address: bech32Address,
                message: challenge.message,
                signature_pq_b64: pqB64,
            });
            if (result.error) throw new Error(result.error);

            status("Connected — reloading…");
            window.location.reload();
        } catch (err) {
            const message = String((err && err.message) || err);
            const hint = qorexNetworkHint(message);
            status(
                `<span style="color:#fda4af">QoreX: ${message}</span>` +
                    (hint ? `<br><br><span style="color:#e2e8f0">${hint}</span>` : "")
            );
        }
    }

    async function connectEvm(entry) {
        const provider = entry.provider;
        localStorage.setItem(STORAGE_KEY, entry.info.rdns || entry.info.uuid);
        try {
            status(`Waiting for ${entry.info.name}…`);
            const accounts = await provider.request({ method: "eth_requestAccounts" });
            const address = accounts[0];
            state.address = address;

            state.chainId = await provider.request({ method: "eth_chainId" });
            if (state.chainId !== DIANA.chainId) {
                status(`Switching ${entry.info.name} to Diana…`);
                await switchToDiana(provider);
                state.chainId = await provider.request({ method: "eth_chainId" });
                if (state.chainId !== DIANA.chainId) {
                    throw new Error("please switch this wallet to QoreChain Diana (chain ID 9800)");
                }
            }

            status("Sign the login message…");
            const challenge = await fetch(
                `/api/wallet/challenge/?address=${encodeURIComponent(address)}`,
                { headers: { Accept: "application/json" } }
            ).then((r) => r.json());

            const signature = await provider.request({
                method: "personal_sign",
                params: [challenge.message, address],
            });

            status("Verifying…");
            const result = await jsonPost("/api/wallet/verify/", {
                method: "evm",
                address,
                message: challenge.message,
                signature,
            });
            if (result.error) throw new Error(result.error);

            status("Connected — reloading…");
            window.location.reload();
        } catch (err) {
            status(`<span style="color:#fda4af">${entry.info.name}: ${(err && err.message) || err}</span>`);
        }
    }

    async function disconnect() {
        try {
            await jsonPost("/api/wallet/logout/", {});
        } catch (e) {
            /* fall through to reload */
        }
        window.location.reload();
    }

    // ------------------------------------------------------------------
    // Transactions (EVM actions) — uses the selected EIP-6963 provider
    // ------------------------------------------------------------------

    async function switchToDiana(provider) {
        try {
            await provider.request({
                method: "wallet_switchEthereumChain",
                params: [{ chainId: DIANA.chainId }],
            });
        } catch (err) {
            if (err && (err.code === 4902 || /Unrecognized chain|not added/i.test(err.message || ""))) {
                await provider.request({
                    method: "wallet_addEthereumChain",
                    params: [
                        {
                            chainId: DIANA.chainId,
                            chainName: DIANA.chainName,
                            nativeCurrency: DIANA.nativeCurrency,
                            rpcUrls: DIANA.rpcUrls,
                            blockExplorerUrls: DIANA.blockExplorerUrls,
                        },
                    ],
                });
            } else {
                throw err;
            }
        }
    }

    async function requireEvmProvider() {
        await discoverEvmProviders();
        const provider = selectedEvmProvider();
        if (!provider) {
            throw new Error(
                "No EVM wallet available. Install QoreX (it provides both lanes) or any EVM wallet, then reload."
            );
        }
        return provider;
    }

    async function sendTx({ to, data, value = 0n }) {
        const provider = await requireEvmProvider();
        const accounts = await provider.request({ method: "eth_requestAccounts" });
        const from = accounts[0];
        const chainId = await provider.request({ method: "eth_chainId" });
        if (chainId !== DIANA.chainId) {
            await switchToDiana(provider);
        }
        const tx = { from, to, data };
        if (value > 0n) tx.value = "0x" + value.toString(16);
        return provider.request({ method: "eth_sendTransaction", params: [tx] });
    }

    async function copyAddress() {
        try {
            await navigator.clipboard.writeText(window.SWEEFT_WALLET_EVM || "");
        } catch (e) {
            /* clipboard unavailable */
        }
    }

    // Discover early so sendTx works without opening the modal first.
    discoverEvmProviders().catch(() => {});

    window.SweeftWallet = {
        openModal,
        closeModal,
        connectQorex,
        connectEvm,
        disconnect,
        sendTx,
        copyAddress,
        shortAddress,
        evmProviders,
        state,
        config: DIANA,
    };
})();
