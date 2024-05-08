# my unix scripts

My unix scripts, which are convenient to call using iterm or terminal.

## Usage

1. Clone this repository, and add the directory to your PATH environment variable.

For zsh:

```{zsh}
git clone https://github.com/Sigurd-git/Unix-scripts.git
cd Unix-scripts
echo "PATH=$PWD:$PATH">> ~/.zshrc
source ~/.zshrc
```

For bash:

```{bash}
git clone https://github.com/Sigurd-git/Unix-scripts.git
cd Unix-scripts
echo "PATH=$PWD:$PATH">> ~/.bashrc
source ~/.bashrc
```

2. Change the file mode to executable.

```
chmod 755 *
```

3. Create a file named user_password.txt in the same directory as the script file, and write your bluehive account in the first line, like:

```
username
password
```

4. Set the ssh config file, like:

```
Host *
    ControlMaster auto
    ControlPath /tmp/ssh_mux_%h_%p_%r

Host bluehive
	Hostname bluehive.circ.rochester.edu
	User username
	ControlMaster auto
	ControlPath /tmp/ssh_bluehive

```
