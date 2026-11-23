import { Accordion } from "@/app/_components/Accordion.tsx";
import { ExternalLinkIcon } from "@/app/_components/ExternalLinkIcon.tsx";

export function Prerequisites() {
  return (
    <Accordion summary="Carbon, Iocaste Untether and OpenSSH" className="mt-2">
      <div className="mx-4 border-t border-border py-4">
        <a
          href="http://carbon.sep.lol/"
          target="_blank"
          className="inline-flex items-center gap-1 rounded-lg border
            border-accent-border bg-accent-soft px-4 py-2.75
            text-accent-soft-foreground hover:bg-accent
            hover:text-accent-foreground focus-visible:outline-2
            focus-visible:outline-offset-2 focus-visible:outline-foreground
            active:bg-accent active:text-accent-foreground"
        >
          Carbon
          <ExternalLinkIcon className="size-4" />
        </a>
        <ol className="mt-5 list-decimal space-y-2 pl-6 text-muted">
          <li>
            Use Carbon to install the Carbon jailbreak on your device.
            <ul className="mt-2 list-[circle] space-y-2 pl-5">
              <li>Open the Carbon website by clicking the button above.</li>
              <li>
                Click &quot;Install Certs&quot; at the top of the page, and
                follow the instructions in the settings app to approve the
                certifications.
              </li>
              <li>
                Return to the website, and then press the blue &quot;Run&quot;
                button.
              </li>
              <li>
                You may have to press the Run button many times before the
                jailbreak works. This is normal. Once the button says
                &quot;Exploiting&quot; for an extended period of time, do not
                interact with the device until it has rebooted.
              </li>
            </ul>
          </li>
          <li>
            After Carbon has successfully been installed, open the Cydia app
            that you now have on the home screen.
          </li>
          <li>
            Wait for packages to automatically refresh and update. Choose
            &quot;Complete Upgrade&quot; if prompted. You can manually refresh
            the software sources as well by navigating to the Sources page.
          </li>
          <li>
            Navigate to the Search page and search &quot;iocaste untether&quot;.
            iocaste untether is an untethered jailbreak and system package
            created by staturnz for 32-bit iOS devices running iOS 9.3.5 or iOS
            9.3.6.
          </li>
          <li>
            Install the iocaste untether package by staturnz. Wait for the
            installation to complete, then tap &quot;Reboot Device&quot;.
          </li>
          <li>
            Return to the Search page and search &quot;OpenSSH&quot;. Install
            the OpenSSH package by Jay Freeman (saurik).
          </li>
        </ol>
        <p className="mt-5 text-muted">
          After you have installed Carbon, iocaste untether and OpenSSH, you are
          ready to move on to installing FleetFinch.
        </p>
      </div>
    </Accordion>
  );
}
