/**
 * Sweeft wallet manager — EVM wallet connection for the Diana testnet.
 *
 * Handles: connect/disconnect display, account + chain watching, adding the
 * QoreChain Diana network to the wallet, and a shared sendTransaction helper
 * the action buttons use. Exposes window.SweeftWallet.
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

    function provider() {
        return window.ethereum || null;
    }

    function truncate(address) {
        return address ? address.slice(0, 6) + "…" + address.slice(-4) : "";
    }

    function render() {
        const widget = document.getElementById("wallet-widget");
        if (!widget) return;

        const hasProvider = !!provider();
        if (!hasProvider) {
            widget.innerHTML =
                '<a href="https://qorechain.io/qorex" target="_blank" class="inline-flex h-9 items-center rounded-lg border border-slate-700 px-3 text-xs text-slate-300 hover:border-teal-500/50 hover:text-teal-300 transition-colors">Install MetaMask or QoreX</a>';
            return;
        }
        if (!state.address) {
            widget.innerHTML =
                '<button id="wallet-connect" class="inline-flex h-9 items-center rounded-lg bg-teal-500 px-3.5 text-sm font-semibold text-slate-950 hover:bg-teal-400 transition-colors">Connect wallet</button>';
            document.getElementById("wallet-connect").addEventListener("click", connect);
            return;
        }
        const onDiana = state.chainId === DIANA.chainId;
        widget.innerHTML =
            '<div class="flex items-center gap-2">' +
            '<span class="hidden sm:inline-flex h-9 items-center rounded-lg border ' +
            (onDiana
                ? "border-teal-500/30 text-teal-400"
                : "border-amber-500/40 text-amber-400 cursor-pointer") +
            ' px-3 text-xs" ' +
            (onDiana ? "" : 'id="wallet-switch" title="Click to switch to Diana"') +
            ">" +
            (onDiana ? "Diana · " : "Wrong network · ") +
            truncate(state.address) +
            "</span>" +
            "</div>";
        const switchButton = document.getElementById("wallet-switch");
        if (switchButton) switchButton.addEventListener("click", switchToDiana);
    }

    async function connect() {
        const eth = provider();
        if (!eth) return null;
        try {
            const accounts = await eth.request({ method: "eth_requestAccounts" });
            state.address = accounts[0] || null;
            state.chainId = await eth.request({ method: "eth_chainId" });
            render();
            if (state.chainId !== DIANA.chainId) await switchToDiana();
            document.dispatchEvent(new CustomEvent("sweeft:wallet", { detail: { ...state } }));
            return state.address;
        } catch (err) {
            alert("Wallet connection failed: " + (err.message || err));
            return null;
        }
    }

    async function switchToDiana() {
        const eth = provider();
        if (!eth) return;
        try {
            await eth.request({
                method: "wallet_switchEthereumChain",
                params: [{ chainId: DIANA.chainId }],
            });
        } catch (err) {
            // 4902 = unknown chain — add it instead.
            if (err && (err.code === 4902 || err.code === -32603 || /Unrecognized chain/i.test(err.message || ""))) {
                try {
                    await eth.request({
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
                } catch (addErr) {
                    alert(
                        "Could not add QoreChain Diana to your wallet.\n" +
                            "Add it manually — RPC https://evm-testnet.qore.host, chain ID 9800, symbol QOR."
                    );
                }
            }
        }
        state.chainId = await eth.request({ method: "eth_chainId" });
        render();
    }

    async function requireAddress() {
        if (!provider()) {
            throw new Error(
                "No EVM wallet found. Install MetaMask (or the QoreX browser wallet) and reload this page."
            );
        }
        if (!state.address) {
            const address = await connect();
            if (!address) throw new Error("Wallet not connected.");
        }
        if (state.chainId !== DIANA.chainId) {
            await switchToDiana();
            if (state.chainId !== DIANA.chainId) {
                throw new Error("Please switch your wallet to QoreChain Diana (chain ID 9800).");
            }
        }
        return state.address;
    }

    /** Send one EVM transaction from the connected wallet. */
    async function sendTx({ to, data, value = 0n }) {
        const eth = provider();
        const from = await requireAddress();
        const tx = { from, to, data };
        if (value > 0n) tx.value = "0x" + value.toString(16);
        return eth.request({ method: "eth_sendTransaction", params: [tx] });
    }

    // Watch for account/chain changes from the wallet side.
    if (provider()) {
        provider().on?.("accountsChanged", (accounts) => {
            state.address = accounts[0] || null;
            render();
        });
        provider().on?.("chainChanged", (chainId) => {
            state.chainId = chainId;
            render();
        });
        // Silent initial probe (no popup).
        provider()
            .request({ method: "eth_accounts" })
            .then(async (accounts) => {
                state.address = accounts[0] || null;
                if (state.address) state.chainId = await provider().request({ method: "eth_chainId" });
                render();
            })
            .catch(() => render());
    }

    document.addEventListener("DOMContentLoaded", render);

    window.SweeftWallet = {
        connect,
        switchToDiana,
        requireAddress,
        sendTx,
        state,
        config: DIANA,
    };
})();
