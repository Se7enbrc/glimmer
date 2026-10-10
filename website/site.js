const copyButton = document.querySelector('#copy-brew');
const copyStatus = document.querySelector('#copy-status');
const brewCommand = document.querySelector('#brew-command');

if (navigator.clipboard) {
    copyButton.hidden = false;
    copyButton.addEventListener('click', async () => {
        copyButton.disabled = true;
        try {
            await navigator.clipboard.writeText(brewCommand.textContent.trim());
            copyButton.textContent = 'Copied';
            copyStatus.textContent = 'Paste the command into Terminal.';
        } catch {
            copyButton.textContent = 'Copy command';
            copyStatus.textContent = "Couldn't copy. Select the command and copy it manually.";
        } finally {
            copyButton.disabled = false;
        }
    });
}

const appWindow = document.querySelector('#app-window');
const tiles = [...document.querySelectorAll('[data-app]')];
const status = document.querySelector('#demo-status');
const readiness = document.querySelector('#readiness-label');
const resetButton = document.querySelector('#reset-demo');
let connectionTimer;
let activeTile;

function setState(state) {
    appWindow.dataset.state = state;
    readiness.textContent = state === 'ready' ? 'Ready · 5 ms'
        : state === 'connecting' ? 'Connecting to Den PC…' : 'Streaming';
    resetButton.hidden = state === 'ready';
    tiles.forEach(tile => {
        const selected = tile === activeTile && state !== 'ready';
        tile.disabled = state !== 'ready' && !selected;
        tile.querySelector('.play-icon').hidden = selected;
        tile.querySelector('.spinner').hidden = !(selected && state === 'connecting');
        tile.querySelector('.back-to-stream').hidden = !(selected && state === 'streaming');
        const action = !selected ? `Stream ${tile.dataset.app}`
            : state === 'connecting' ? `${tile.dataset.app}, cancel the connection`
                : `${tile.dataset.app}, Back to Stream`;
        tile.setAttribute('aria-label', action);
    });
}

function resetDemo() {
    clearTimeout(connectionTimer);
    setState('ready');
    status.textContent = 'Den PC is ready.';
    activeTile?.focus({ preventScroll: true });
}

function selectApp(tile) {
    if (appWindow.dataset.state !== 'ready') {
        resetDemo();
        return;
    }
    activeTile = tile;
    setState('connecting');
    status.textContent = 'Connecting to Den PC…';
    connectionTimer = setTimeout(() => {
        setState('streaming');
        status.textContent = `${tile.dataset.app} is streaming. Back to Stream resets the launcher replica.`;
    }, 1100);
}

tiles.forEach(tile => tile.addEventListener('click', () => selectApp(tile)));
resetButton.addEventListener('click', resetDemo);
document.querySelector('.demo').addEventListener('keydown', event => {
    if (event.key === 'Escape' && appWindow.dataset.state === 'connecting') {
        event.preventDefault();
        resetDemo();
    }
});
setState('ready');
