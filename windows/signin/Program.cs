// AlexLMP: Google sign-in window for YouTube Music on Windows.
//
// Opens Google's normal sign-in page in a small window (WebView2, the Edge
// engine built into Windows). Every sign-in starts fresh, so you can pick or
// add any Google account. When YouTube Music has loaded signed in, prints its
// cookies on one line and exits 0. Closing the window exits 1.
using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

static class Program
{
    const string LoginUrl =
        "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube" +
        "&passive=true&continue=https%3A%2F%2Fmusic.youtube.com%2F";
    const string CookieUrl = "https://music.youtube.com/";

    [STAThread]
    static int Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        string result = null;
        // A brand-new profile every time, deleted afterwards.
        var profile = Path.Combine(Path.GetTempPath(),
            "alexlmp-signin-" + Guid.NewGuid().ToString("N"));

        var form = new Form
        {
            Text = "Sign in to YouTube Music",
            Width = 500,
            Height = 760,
            StartPosition = FormStartPosition.CenterScreen,
        };
        var web = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(web);

        form.Load += async (s, e) =>
        {
            try
            {
                var env = await CoreWebView2Environment.CreateAsync(null, profile);
                await web.EnsureCoreWebView2Async(env);
                web.CoreWebView2.NavigationCompleted += async (s2, e2) =>
                {
                    var uri = web.Source?.ToString() ?? "";
                    if (!uri.StartsWith("https://music.youtube.com")) return;
                    var cookies =
                        await web.CoreWebView2.CookieManager.GetCookiesAsync(CookieUrl);
                    var text = string.Join("; ", cookies.Select(c => c.Name + "=" + c.Value));
                    if (text.Contains("SAPISID="))
                    {
                        result = text;
                        form.Close();
                    }
                };
                web.CoreWebView2.Navigate(LoginUrl);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                MessageBox.Show(
                    "The sign-in window needs Microsoft Edge WebView2 Runtime " +
                    "(https://go.microsoft.com/fwlink/p/?LinkId=2124703).\n\n" +
                    "Details: " + ex.Message,
                    "AlexLMP", MessageBoxButtons.OK, MessageBoxIcon.Error);
                form.Close();
            }
        };

        Application.Run(form);

        try { web.Dispose(); } catch { }
        for (var i = 0; i < 10; i++)
        {
            try { if (Directory.Exists(profile)) Directory.Delete(profile, true); break; }
            catch { Task.Delay(300).Wait(); }
        }

        if (result != null)
        {
            Console.Out.Write(result);
            Console.Out.Flush();
            return 0;
        }
        return 1;
    }
}
