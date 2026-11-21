/**
 * Sweeft wallet — connect, session login, and transaction helpers.
 *
 * Connection is a server-side session: the wallet signs a one-time challenge
 * (QoreX with its ML-DSA-87 key, or an EVM wallet with personal_sign), the
 * server verifies it and the page reloads as connected. Action buttons use
 * SweeftWallet.sendTx for EVM transactions.
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

    const state = { address: null, chainId: null };

    function csrf() {
        const meta = document.querySelector('meta[name="csrf-token"]');
        return meta ? meta.content : "";
    }

    function qorex() {
        return window.qorex && window.qorex.native ? window.qorex.native : null;
    }

    function evmProvider() {
        return window.ethereum || null;
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
            "background:rgba(2,6,23,0.7);backdrop-filter:blur(4px)";
        el.innerHTML =
            '<div style="width:min(26rem,92vw);background:#0f172a;border:1px solid #1e293b;border-radius:16px;padding:20px">' +
            '<div style="display:flex;justify-content:space-between;align-items:center">' +
            '<div style="font-weight:700;color:#e2e8f0">Connect a wallet</div>' +
            '<button id="wallet-modal-close" style="color:#64748b;font-size:18px;line-height:1">×</button>' +
            "</div>" +
            '<div id="wallet-modal-body" style="margin-top:14px"></div>' +
            '<div id="wallet-modal-status" style="margin-top:12px;font-size:12px;color:#94a3b8"></div>' +
            "</div>";
        document.body.appendChild(el);
        el.addEventListener("click", (event) => {
            if (event.target === el) closeModal();
        });
        el.querySelector("#wallet-modal-close").addEventListener("click", closeModal);
        return el;
    }

    function optionButton(id, title, subtitle, enabled) {
        return (
            `<button id="${id}" ${enabled ? "" : "disabled"} style="width:100%;text-align:left;display:flex;` +
            "gap:12px;align-items:center;border:1px solid #1e293b;border-radius:12px;padding:12px;margin-bottom:10px;" +
            (enabled ? "cursor:pointer;background:#0b1220" : "cursor:not-allowed;opacity:0.5;background:#0b1220") +
            '">' +
            `<div style="width:36px;height:36px;border-radius:10px;background:#134e4a;color:#5eead4;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:13px">${title[0]}</div>` +
            `<div><div style="color:#e2e8f0;font-weight:600;font-size:14px">${title}</div>` +
            `<div style="color:#64748b;font-size:12px">${subtitle}</div></div>` +
            "</button>"
        );
    }

    function renderOptions() {
        const body = modal().querySelector("#wallet-modal-body");
        const hasQorex = !!qorex();
        const hasEvm = !!evmProvider();
        body.innerHTML =
            optionButton("wallet-pick-qorex", "QoreX", "QoreChain wallet — post-quantum signing", hasQorex) +
            optionButton("wallet-pick-evm", "MetaMask / EVM wallet", "Classical signing for EVM actions", hasEvm) +
            (!hasQorex && !hasEvm
                ? '<p style="color:#94a3b8;font-size:12px;line-height:1.6">No wallet extension detected in this browser. ' +
                  'Install the <a style="color:#5eead4" href="https://qorechain.io/qorex" target="_blank">QoreX wallet</a> ' +
                  '(recommended — required for post-quantum signing) or MetaMask, then reload this page.</p>'
                : "");
        if (hasQorex) document.getElementById("wallet-pick-qorex").addEventListener("click", connectQorex);
        if (hasEvm) document.getElementById("wallet-pick-evm").addEventListener("click", connectEvm);
    }

    function status(text) {
        const el = modal().querySelector("#wallet-modal-status");
        if (el) el.textContent = text || "";
    }

    function openModal() {
        renderOptions();
        status("");
        modal().style.display = "flex";
    }

    function closeModal() {
        const el = document.getElementById("wallet-modal");
        if (el) el.style.display = "none";
    }

    // ------------------------------------------------------------------
    // Connect flows
    // ------------------------------------------------------------------

    async function connectQorex() {
        const provider = qorex();
        if (!provider) return;
        try {
            status("Waiting for QoreX…");
            await provider.enable("qorechain-diana");
            const { bech32Address } = await provider.getKey("qorechain-diana");

            status("Sign the login message in QoreX…");
            const challenge = await fetch(
                `/api/wallet/challenge/?address=${encodeURIComponent(bech32Address)}`,
                { headers: { Accept: "application/json" } }
            ).then((r) => r.json());

            const signature = await provider.signArbitrary("qorechain-diana", bech32Address, challenge.message);
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
            status("");
            alert("QoreX connect failed: " + (err.message || err));
        }
    }

    async function connectEvm() {
        const provider = evmProvider();
        if (!provider) return;
        try {
            status("Waiting for the wallet…");
            const accounts = await provider.request({ method: "eth_requestAccounts" });
            const address = accounts[0];
            state.address = address;

            // Make sure we are on Diana before signing.
            state.chainId = await provider.request({ method: "eth_chainId" });
            if (state.chainId !== DIANA.chainId) {
                await switchToDiana();
                state.chainId = await provider.request({ method: "eth_chainId" });
                if (state.chainId !== DIANA.chainId) throw new Error("Please switch to QoreChain Diana (9800)");
            }

            status("Sign the login message in your wallet…");
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
            status("");
            alert("Connect failed: " + (err.message || err));
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
    // Transactions (EVM actions)
    // ------------------------------------------------------------------

    async function switchToDiana() {
        const provider = evmProvider();
        if (!provider) return;
        try {
            await provider.request({
                method: "wallet_switchEthereumChain",
                params: [{ chainId: DIANA.chainId }],
            });
        } catch (err) {
            if (err && (err.code === 4902 || /Unrecognized chain/i.test(err.message || ""))) {
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

    async function requireAddress() {
        const provider = evmProvider();
        if (!provider) {
            throw new Error(
                "This action needs an EVM wallet (MetaMask) connected to QoreChain Diana. " +
                    "Use the Connect wallet button in the nav."
            );
        }
        const accounts = await provider.request({ method: "eth_requestAccounts" });
        const address = accounts[0];
        state.address = address;
        state.chainId = await provider.request({ method: "eth_chainId" });
        if (state.chainId !== DIANA.chainId) {
            await switchToDiana();
            state.chainId = await provider.request({ method: "eth_chainId" });
            if (state.chainId !== DIANA.chainId) {
                throw new Error("Please switch your wallet to QoreChain Diana (chain ID 9800).");
            }
        }
        return address;
    }

    async function sendTx({ to, data, value = 0n }) {
        const provider = evmProvider();
        const from = await requireAddress();
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

    window.SweeftWallet = {
        openModal,
        closeModal,
        connectQorex,
        connectEvm,
        disconnect,
        switchToDiana,
        requireAddress,
        sendTx,
        copyAddress,
        state,
        config: DIANA,
    };
})();
