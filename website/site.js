const copyButton = document.querySelector('#copy-brew');
const copyStatus = document.querySelector('#copy-status');
const brewCommand = document.querySelector('#brew-command');

if (copyButton && copyStatus && brewCommand && navigator.clipboard) {
    copyButton.hidden = false;
    copyButton.addEventListener('click', async () => {
        copyButton.disabled = true;
        try {
            await navigator.clipboard.writeText(brewCommand.textContent.trim());
            copyButton.textContent = 'Copied';
            copyStatus.textContent = 'Copied. Paste the command into Terminal.';
        } catch {
            copyButton.textContent = 'Copy';
            copyStatus.textContent = "Couldn't copy. Select the command above and copy it manually.";
        } finally {
            copyButton.disabled = false;
        }
    });
}
