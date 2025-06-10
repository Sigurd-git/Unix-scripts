#!/usr/bin/env python3
"""
Cluster Manager GUI

A two-page GUI for managing tunnel.sh script execution.
Page 1: User authentication and SSH connection establishment
Page 2: Parameter configuration and script execution with real-time output
"""

import tkinter as tk
from tkinter import ttk, messagebox, filedialog, scrolledtext
from tkinter import font as tkFont
import os
import subprocess
import sys
import threading
import queue
from pathlib import Path


# Modern color scheme constants
class Colors:
    # Primary colors
    PRIMARY = "#2C3E50"  # Dark blue-gray
    SECONDARY = "#3498DB"  # Blue
    SUCCESS = "#27AE60"  # Green
    WARNING = "#F39C12"  # Orange
    ERROR = "#E74C3C"  # Red

    # Background colors
    BG_LIGHT = "#ECF0F1"  # Light gray
    BG_CARD = "#FFFFFF"  # White
    BG_DARK = "#34495E"  # Dark gray

    # Text colors
    TEXT_PRIMARY = "#2C3E50"  # Dark text
    TEXT_SECONDARY = "#7F8C8D"  # Gray text
    TEXT_LIGHT = "#FFFFFF"  # White text
    TEXT_MUTED = "#95A5A6"  # Muted text

    # Border colors
    BORDER_LIGHT = "#BDC3C7"  # Light border
    BORDER_FOCUS = "#3498DB"  # Focus border

    # Gradient colors
    GRADIENT_START = "#3498DB"  # Gradient start
    GRADIENT_END = "#2980B9"  # Gradient end


# Font configurations
class Fonts:
    TITLE = ("Segoe UI", 16, "bold")
    SUBTITLE = ("Segoe UI", 14, "bold")
    HEADING = ("Segoe UI", 12, "bold")
    BODY = ("Segoe UI", 10)
    SMALL = ("Segoe UI", 9)
    MONOSPACE = ("Consolas", 10)


class LoginPage:
    """
    Login page for user authentication and SSH connection establishment.

    Handles:
    - User authentication with persistent storage
    - Cluster selection with hostname mapping
    - SSH connection testing
    - Transition to main functionality page
    """

    def __init__(self, root, app_controller):
        """
        Initialize the login page.

        Args:
            root (tk.Tk): The main tkinter window
            app_controller: Reference to the application controller
        """
        self.root = root
        self.app_controller = app_controller

        # Initialize variables
        self.user_var = tk.StringVar()
        self.password_var = tk.StringVar()
        self.cluster_var = tk.StringVar(value="bluehive")
        self.remember_password = tk.BooleanVar()
        self.password_visible = tk.BooleanVar(value=False)

        # Setup modern styles
        self.setup_modern_styles()

        # Create the login interface
        self.create_login_widgets()
        self.load_user_credentials()

    def setup_modern_styles(self):
        """Configure modern ttk styles for the login page."""
        style = ttk.Style()
        style.theme_use("clam")

        # Configure modern card frame
        style.configure(
            "Card.TFrame", background=Colors.BG_CARD, relief="flat", borderwidth=0
        )

        # Configure modern label frame
        style.configure(
            "CardLabel.TLabelframe",
            background=Colors.BG_CARD,
            relief="flat",
            borderwidth=2,
            lightcolor=Colors.BORDER_LIGHT,
            darkcolor=Colors.BORDER_LIGHT,
            focuscolor=Colors.BORDER_FOCUS,
        )

        style.configure(
            "CardLabel.TLabelframe.Label",
            background=Colors.BG_CARD,
            foreground=Colors.TEXT_PRIMARY,
            font=Fonts.HEADING,
        )

        # Configure modern entries
        style.configure(
            "Modern.TEntry",
            fieldbackground=Colors.BG_LIGHT,
            borderwidth=2,
            relief="flat",
            focuscolor=Colors.BORDER_FOCUS,
            font=Fonts.BODY,
        )

        # Configure modern buttons
        style.configure(
            "Primary.TButton",
            background=Colors.SECONDARY,
            foreground=Colors.TEXT_LIGHT,
            borderwidth=0,
            relief="flat",
            font=Fonts.BODY,
            focuscolor="none",
        )

        style.map(
            "Primary.TButton",
            background=[("active", Colors.GRADIENT_END), ("pressed", Colors.PRIMARY)],
        )

        style.configure(
            "Secondary.TButton",
            background=Colors.BG_LIGHT,
            foreground=Colors.TEXT_PRIMARY,
            borderwidth=1,
            relief="flat",
            font=Fonts.SMALL,
        )

        # Configure modern labels
        style.configure(
            "Title.TLabel",
            background=Colors.BG_LIGHT,
            foreground=Colors.PRIMARY,
            font=Fonts.TITLE,
        )

        style.configure(
            "Body.TLabel",
            background=Colors.BG_CARD,
            foreground=Colors.TEXT_PRIMARY,
            font=Fonts.BODY,
        )

        style.configure("Status.TLabel", background=Colors.BG_LIGHT, font=Fonts.BODY)

    def create_login_widgets(self):
        """Create the modern login page widgets."""
        # Clear the window
        for widget in self.root.winfo_children():
            widget.destroy()

        # Configure window
        self.root.title("Cluster Manager - Login")
        self.root.geometry("800x600")
        self.root.configure(bg=Colors.BG_LIGHT)

        # Main container with modern styling
        main_frame = tk.Frame(self.root, bg=Colors.BG_LIGHT)
        main_frame.pack(fill=tk.BOTH, expand=True, padx=40, pady=40)

        # Title section
        title_frame = tk.Frame(main_frame, bg=Colors.BG_LIGHT)
        title_frame.pack(fill=tk.X, pady=(0, 40))

        title_label = ttk.Label(
            title_frame, text="🚀 Cluster Manager", style="Title.TLabel"
        )
        title_label.pack()

        subtitle_label = ttk.Label(
            title_frame,
            text="High Performance Computing Connection Hub",
            style="Status.TLabel",
        )
        subtitle_label.configure(foreground=Colors.TEXT_SECONDARY)
        subtitle_label.pack(pady=(5, 0))

        # Login card container
        card_container = tk.Frame(main_frame, bg=Colors.BG_LIGHT)
        card_container.pack(expand=True)

        # Create login card with shadow effect
        login_card = tk.Frame(
            card_container, bg=Colors.BG_CARD, relief="flat", borderwidth=0
        )
        login_card.pack(padx=60, pady=20, ipadx=40, ipady=30)

        # Add shadow effect (simple simulation)
        shadow_frame = tk.Frame(card_container, bg=Colors.TEXT_MUTED, height=2)
        shadow_frame.place(in_=login_card, x=5, y=5, relwidth=1, relheight=1)
        login_card.lift()

        # Login form frame
        form_frame = ttk.LabelFrame(
            login_card,
            text="  🔐 Authentication  ",
            style="CardLabel.TLabelframe",
            padding=30,
        )
        form_frame.pack(fill=tk.BOTH, expand=True, padx=20, pady=20)

        # Create form grid
        self.create_form_fields(form_frame)

        # Buttons section
        self.create_login_buttons(login_card)

    def create_form_fields(self, parent):
        """Create modern form input fields."""
        # Configure grid weights
        parent.columnconfigure(1, weight=1)

        # Username field
        ttk.Label(parent, text="👤 Username:", style="Body.TLabel").grid(
            row=0, column=0, sticky=tk.W, pady=(0, 15), padx=(0, 20)
        )

        username_entry = ttk.Entry(
            parent, textvariable=self.user_var, style="Modern.TEntry", width=25
        )
        username_entry.grid(row=0, column=1, sticky=tk.EW, pady=(0, 15))

        # Password field
        ttk.Label(parent, text="🔑 Password:", style="Body.TLabel").grid(
            row=1, column=0, sticky=tk.W, pady=(0, 15), padx=(0, 20)
        )

        # Password entry frame
        password_frame = tk.Frame(parent, bg=Colors.BG_CARD)
        password_frame.grid(row=1, column=1, sticky=tk.EW, pady=(0, 15))
        password_frame.columnconfigure(0, weight=1)

        self.password_entry = ttk.Entry(
            password_frame,
            textvariable=self.password_var,
            show="*",
            style="Modern.TEntry",
            width=20,
        )
        self.password_entry.grid(row=0, column=0, sticky=tk.EW)

        # Password visibility toggle
        self.toggle_password_btn = ttk.Button(
            password_frame,
            text="👁️",
            width=3,
            command=self.toggle_password_visibility,
            style="Secondary.TButton",
        )
        self.toggle_password_btn.grid(row=0, column=1, padx=(10, 0))

        # Cluster selection
        ttk.Label(parent, text="🖥️ Cluster:", style="Body.TLabel").grid(
            row=2, column=0, sticky=tk.W, pady=(0, 15), padx=(0, 20)
        )

        cluster_combo = ttk.Combobox(
            parent,
            textvariable=self.cluster_var,
            values=["bluehive", "bhward"],
            state="readonly",
            style="Modern.TEntry",
            width=22,
        )
        cluster_combo.grid(row=2, column=1, sticky=tk.EW, pady=(0, 15))

        # Remember password checkbox
        remember_frame = tk.Frame(parent, bg=Colors.BG_CARD)
        remember_frame.grid(row=3, column=1, sticky=tk.W, pady=(0, 10))

        remember_cb = ttk.Checkbutton(
            remember_frame,
            text="💾 Remember credentials",
            variable=self.remember_password,
        )
        remember_cb.pack(side=tk.LEFT)

    def create_login_buttons(self, parent):
        """Create modern login buttons and status."""
        # Buttons container
        button_container = tk.Frame(parent, bg=Colors.BG_CARD)
        button_container.pack(fill=tk.X, padx=20, pady=(0, 20))

        # Connect button
        self.connect_btn = ttk.Button(
            button_container,
            text="🚀 Connect to Cluster",
            command=self.connect_to_cluster,
            style="Primary.TButton",
        )
        self.connect_btn.pack(pady=(10, 15), ipadx=20, ipady=8)

        # Status label
        self.status_label = ttk.Label(
            button_container,
            text="🔒 Enter credentials and click Connect",
            style="Status.TLabel",
        )
        self.status_label.configure(foreground=Colors.SECONDARY)
        self.status_label.pack(pady=(0, 10))

    def load_user_credentials(self):
        """Load user credentials from user_password.txt file."""
        user_password_file = Path("user_password.txt")

        if user_password_file.exists():
            content = user_password_file.read_text().strip()
            lines = content.split("\n")

            if len(lines) >= 1:
                self.user_var.set(lines[0].strip())
            if len(lines) >= 2:
                self.password_var.set(lines[1].strip())
                self.remember_password.set(True)

    def save_user_credentials(self):
        """Save user credentials to user_password.txt file."""
        user_password_file = Path("user_password.txt")

        # Always save username
        content = f"{self.user_var.get()}\n"

        user_password_file.write_text(content)

    def save_user_credentials_with_password(self):
        """Save user credentials to user_password.txt file."""
        user_password_file = Path("user_password.txt")

        # Always save username
        content = f"{self.user_var.get()}\n"
        content += f"{self.password_var.get()}"

        user_password_file.write_text(content)

    def toggle_password_visibility(self):
        """Toggle password visibility."""
        self.password_visible.set(not self.password_visible.get())
        if self.password_visible.get():
            self.password_entry.config(show="")
            self.toggle_password_btn.config(text="🙈")
        else:
            self.password_entry.config(show="*")
            self.toggle_password_btn.config(text="👁️")

    def validate_credentials(self):
        """Validate user credentials."""
        if not self.user_var.get():
            messagebox.showerror("Error", "Please enter your username.")
            return False

        if not self.password_var.get():
            messagebox.showerror("Error", "Please enter your password.")
            return False

        return True

    def connect_to_cluster(self):
        """Test SSH connection to cluster."""
        if not self.validate_credentials():
            return

        # Save credentials
        self.save_user_credentials_with_password()

        # Update status
        self.status_label.config(text="Connecting to cluster...", foreground="orange")
        self.connect_btn.config(state=tk.DISABLED)

        # Test connection in background thread
        thread = threading.Thread(target=self.test_ssh_connection)
        thread.daemon = True
        thread.start()

    def test_ssh_connection(self):
        """Test SSH connection in background thread."""
        try:
            # Get hostname based on cluster
            cluster = self.cluster_var.get()

            # Test SSH connection with a simple command
            test_cmd = [
                "./start_ssh_control.sh",
                "-a",
                cluster,
                "echo 'Connection test successful'",
            ]

            result = subprocess.run(
                test_cmd, capture_output=True, text=True, timeout=15
            )

            if result.returncode == 0:
                # Connection successful
                self.root.after(0, self.connection_success)
            else:
                error_msg = result.stderr or "Connection failed"
                self.root.after(0, lambda: self.connection_failed(error_msg))

        except Exception as e:
            error_msg = str(e)
            self.root.after(0, lambda: self.connection_failed(error_msg))

    def connection_success(self):
        """Handle successful connection."""
        self.status_label.config(
            text="✅ Connection successful! Loading main interface...",
            foreground=Colors.SUCCESS,
        )

        # Pass user info to main page
        user_info = {
            "username": self.user_var.get(),
            "password": self.password_var.get(),
            "cluster": self.cluster_var.get(),
            "remember_password": self.remember_password.get(),
        }

        # Switch to main page after brief delay
        self.root.after(1500, lambda: self.app_controller.show_main_page(user_info))
        if not self.remember_password.get():
            self.save_user_credentials()

    def connection_failed(self, error_msg):
        """Handle failed connection."""
        self.status_label.config(text="❌ Connection failed", foreground=Colors.ERROR)
        self.connect_btn.config(state=tk.NORMAL)
        messagebox.showerror(
            "Connection Error", f"Failed to connect to cluster:\n{error_msg}"
        )


class MainPage:
    """
    Main functionality page for cluster management operations.

    Provides interface for:
    - Cluster connection parameter configuration
    - tunnel.sh script execution and monitoring with real-time output
    - pls.sh script execution
    - Cursor server updates
    """

    def __init__(self, root, app_controller, user_info):
        """
        Initialize the main page.

        Args:
            root (tk.Tk): The main tkinter window
            app_controller: Reference to the application controller
            user_info (dict): User authentication information
        """
        self.root = root
        self.app_controller = app_controller
        self.user_info = user_info

        # Define default tunnel parameters
        self.default_params = {
            "cluster": user_info["cluster"],
            "partition": "doppelbock",
            "cpus": "16",
            "gpus": "1",
            "memory": "256",
            "time": "12",
            "node": "",
            "no_log": False,
        }

        # Initialize parameter variables
        self.param_vars = {}

        # Command execution control
        self.current_process = None
        self.output_queue = queue.Queue()
        self.is_running = False

        # Set up GUI components
        self.setup_styles()
        self.create_main_widgets()

        # Start output monitoring
        self.after_id = None
        self.check_queue()

    def setup_styles(self):
        """Configure modern ttk styles for better appearance."""
        style = ttk.Style()
        style.theme_use("clam")

        # Configure custom styles for main page
        style.configure(
            "MainTitle.TLabel",
            font=Fonts.TITLE,
            background=Colors.BG_LIGHT,
            foreground=Colors.PRIMARY,
        )

        style.configure(
            "MainSection.TLabel",
            font=Fonts.HEADING,
            background=Colors.BG_LIGHT,
            foreground=Colors.TEXT_PRIMARY,
        )

        style.configure("MainFrame.TFrame", background=Colors.BG_LIGHT)

        style.configure(
            "MainCard.TLabelframe",
            background=Colors.BG_CARD,
            relief="flat",
            borderwidth=2,
            lightcolor=Colors.BORDER_LIGHT,
            darkcolor=Colors.BORDER_LIGHT,
        )

        style.configure(
            "MainCard.TLabelframe.Label",
            background=Colors.BG_CARD,
            foreground=Colors.TEXT_PRIMARY,
            font=Fonts.HEADING,
        )

        # Button styles for main page
        style.configure(
            "MainAction.TButton",
            font=Fonts.BODY,
            background=Colors.SECONDARY,
            foreground=Colors.TEXT_LIGHT,
            borderwidth=0,
            relief="flat",
            focuscolor="none",
        )

        style.map(
            "MainAction.TButton",
            background=[("active", Colors.GRADIENT_END), ("pressed", Colors.PRIMARY)],
        )

        style.configure(
            "MainControl.TButton",
            font=Fonts.SMALL,
            background=Colors.BG_LIGHT,
            foreground=Colors.TEXT_PRIMARY,
            borderwidth=1,
            relief="flat",
        )

        style.configure(
            "Success.TButton",
            background=Colors.SUCCESS,
            foreground=Colors.TEXT_LIGHT,
            borderwidth=0,
            relief="flat",
            font=Fonts.BODY,
        )

        style.configure(
            "Warning.TButton",
            background=Colors.WARNING,
            foreground=Colors.TEXT_LIGHT,
            borderwidth=0,
            relief="flat",
            font=Fonts.BODY,
        )

        style.configure(
            "Error.TButton",
            background=Colors.ERROR,
            foreground=Colors.TEXT_LIGHT,
            borderwidth=0,
            relief="flat",
            font=Fonts.BODY,
        )

        # Modern entry style
        style.configure(
            "MainEntry.TEntry",
            fieldbackground=Colors.BG_LIGHT,
            borderwidth=2,
            relief="flat",
            focuscolor=Colors.BORDER_FOCUS,
            font=Fonts.BODY,
        )

        # Status label styles
        style.configure(
            "MainStatus.TLabel", background=Colors.BG_LIGHT, font=Fonts.BODY
        )

    def create_main_widgets(self):
        """Create and layout all main page widgets."""
        # Clear the window
        for widget in self.root.winfo_children():
            widget.destroy()

        # Configure window
        self.root.title(
            f"🚀 Cluster Manager - {self.user_info['cluster']} ({self.user_info['username']})"
        )
        self.root.geometry("1000x900")
        self.root.configure(bg=Colors.BG_LIGHT)

        # Main container with modern styling
        main_frame = tk.Frame(self.root, bg=Colors.BG_LIGHT)
        main_frame.pack(fill=tk.BOTH, expand=True, padx=30, pady=30)

        # Create top container for header and controls (50% of height)
        top_container = tk.Frame(main_frame, bg=Colors.BG_LIGHT)
        top_container.pack(fill=tk.BOTH, expand=True)

        # Create bottom container for terminal output (50% of height)
        bottom_container = tk.Frame(main_frame, bg=Colors.BG_LIGHT)
        bottom_container.pack(fill=tk.BOTH, expand=True)

        # Header with connection info and logout
        header_frame = tk.Frame(top_container, bg=Colors.BG_LIGHT)
        header_frame.pack(fill=tk.X, pady=(0, 15))

        # Title section with modern styling
        title_section = tk.Frame(header_frame, bg=Colors.BG_LIGHT)
        title_section.pack(side=tk.LEFT, fill=tk.X, expand=True)

        title_label = ttk.Label(
            title_section,
            text=f"🖥️ Connected to {self.user_info['cluster'].upper()}",
            style="MainTitle.TLabel",
        )
        title_label.pack(side=tk.LEFT)

        # Connection indicator
        status_indicator = tk.Label(
            title_section, text="🟢", bg=Colors.BG_LIGHT, font=("Arial", 14)
        )
        status_indicator.pack(side=tk.LEFT, padx=(10, 0))

        # User info and logout section
        user_section = tk.Frame(header_frame, bg=Colors.BG_LIGHT)
        user_section.pack(side=tk.RIGHT)

        user_label = ttk.Label(
            user_section,
            text=f"👤 {self.user_info['username']}",
            style="MainStatus.TLabel",
        )
        user_label.configure(foreground=Colors.TEXT_SECONDARY)
        user_label.pack(side=tk.LEFT, padx=(0, 15))

        # Logout button
        logout_btn = ttk.Button(
            user_section,
            text="🚪 Logout",
            command=self.logout,
            style="MainControl.TButton",
        )
        logout_btn.pack(side=tk.RIGHT)

        # Info section
        info_section = tk.Frame(top_container, bg=Colors.BG_LIGHT)
        info_section.pack(fill=tk.X, pady=(0, 15))

        info_label = ttk.Label(
            info_section,
            text="⚙️ Configure parameters and execute cluster management scripts • Real-time output monitoring",
            style="MainStatus.TLabel",
        )
        info_label.configure(foreground=Colors.SUCCESS)
        info_label.pack()

        # Connection Parameters Section
        self.create_params_section(top_container)

        # Separator
        separator2 = ttk.Separator(top_container, orient="horizontal")
        separator2.pack(fill=tk.X, pady=10)

        # Action Buttons Section
        self.create_buttons_section(top_container)

        # Separator
        separator3 = ttk.Separator(main_frame, orient="horizontal")
        separator3.pack(fill=tk.X, pady=10)

        # Output Display Section (takes bottom container = 50% of height)
        self.create_output_section(bottom_container)

    def create_params_section(self, parent):
        """Create connection parameters configuration widgets."""
        params_frame = ttk.LabelFrame(
            parent,
            text="  ⚙️ Connection Parameters  ",
            style="MainCard.TLabelframe",
            padding=15,
        )
        params_frame.pack(fill=tk.X, pady=(0, 8))

        # Initialize parameter variables with default values
        for key, default_value in self.default_params.items():
            if key == "no_log":
                self.param_vars[key] = tk.BooleanVar(value=default_value)
            else:
                self.param_vars[key] = tk.StringVar(value=str(default_value))

        # Create input fields in a grid layout
        # Configure grid weights for responsive design
        params_frame.columnconfigure(1, weight=1)
        params_frame.columnconfigure(3, weight=1)

        row = 0

        # Cluster info (read-only, showing current connection)
        ttk.Label(params_frame, text="🖥️ Cluster:", style="Body.TLabel").grid(
            row=row, column=0, sticky=tk.W, pady=6, padx=(0, 15)
        )

        cluster_info_frame = tk.Frame(params_frame, bg=Colors.BG_CARD)
        cluster_info_frame.grid(row=row, column=1, sticky=tk.W, pady=6, padx=(0, 30))

        cluster_label = tk.Label(
            cluster_info_frame,
            text=f"🔗 {self.user_info['cluster']}",
            bg=Colors.SECONDARY,
            fg=Colors.TEXT_LIGHT,
            font=Fonts.BODY,
            padx=12,
            pady=4,
        )
        cluster_label.pack()

        # Partition
        ttk.Label(params_frame, text="📦 Partition:", style="Body.TLabel").grid(
            row=row, column=2, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Entry(
            params_frame,
            textvariable=self.param_vars["partition"],
            style="MainEntry.TEntry",
            width=18,
        ).grid(row=row, column=3, sticky=tk.EW, pady=6)

        row += 1

        # CPUs
        ttk.Label(params_frame, text="⚡ CPUs:", style="Body.TLabel").grid(
            row=row, column=0, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Entry(
            params_frame,
            textvariable=self.param_vars["cpus"],
            style="MainEntry.TEntry",
            width=18,
        ).grid(row=row, column=1, sticky=tk.EW, pady=6, padx=(0, 30))

        # GPUs
        ttk.Label(params_frame, text="🎯 GPUs:", style="Body.TLabel").grid(
            row=row, column=2, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Entry(
            params_frame,
            textvariable=self.param_vars["gpus"],
            style="MainEntry.TEntry",
            width=18,
        ).grid(row=row, column=3, sticky=tk.EW, pady=6)

        row += 1

        # Memory
        ttk.Label(params_frame, text="💾 Memory (GB):", style="Body.TLabel").grid(
            row=row, column=0, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Entry(
            params_frame,
            textvariable=self.param_vars["memory"],
            style="MainEntry.TEntry",
            width=18,
        ).grid(row=row, column=1, sticky=tk.EW, pady=6, padx=(0, 30))

        # Time
        ttk.Label(params_frame, text="⏰ Time (hours):", style="Body.TLabel").grid(
            row=row, column=2, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Entry(
            params_frame,
            textvariable=self.param_vars["time"],
            style="MainEntry.TEntry",
            width=18,
        ).grid(row=row, column=3, sticky=tk.EW, pady=6)

        row += 1

        # Node (optional)
        ttk.Label(params_frame, text="🎯 Node (optional):", style="Body.TLabel").grid(
            row=row, column=0, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Entry(
            params_frame,
            textvariable=self.param_vars["node"],
            style="MainEntry.TEntry",
            width=18,
        ).grid(row=row, column=1, sticky=tk.EW, pady=6, padx=(0, 30))

        # No Log checkbox with modern styling
        checkbox_frame = tk.Frame(params_frame, bg=Colors.BG_CARD)
        checkbox_frame.grid(
            row=row, column=2, columnspan=2, sticky=tk.W, pady=6, padx=(0, 15)
        )

        ttk.Checkbutton(
            checkbox_frame,
            text="📝 Disable logging",
            variable=self.param_vars["no_log"],
        ).pack(side=tk.LEFT)

    def create_buttons_section(self, parent):
        """Create action buttons section."""
        button_frame = tk.Frame(parent, bg=Colors.BG_LIGHT)
        button_frame.pack(fill=tk.X, pady=8)

        # Left side buttons container
        left_buttons = tk.Frame(button_frame, bg=Colors.BG_LIGHT)
        left_buttons.pack(side=tk.LEFT, fill=tk.X, expand=True)

        # Main action buttons with modern styling
        self.connect_btn = ttk.Button(
            left_buttons,
            text="🚀 Execute tunnel.sh",
            style="MainAction.TButton",
            command=self.connect_cluster,
        )
        self.connect_btn.pack(side=tk.LEFT, padx=(0, 15), ipadx=15, ipady=8)

        # PLS button
        self.pls_btn = ttk.Button(
            left_buttons,
            text="📊 Execute pls.sh",
            style="Success.TButton",
            command=self.execute_pls_script,
        )
        self.pls_btn.pack(side=tk.LEFT, padx=(0, 15), ipadx=15, ipady=8)

        # Stop Command button
        self.stop_btn = ttk.Button(
            left_buttons,
            text="⏹️ Stop Execution",
            style="Error.TButton",
            command=self.stop_command,
            state=tk.DISABLED,
        )
        self.stop_btn.pack(side=tk.LEFT, padx=(0, 15), ipadx=15, ipady=8)

        # Right side - Update Cursor Server button (in corner as requested)
        right_buttons = tk.Frame(button_frame, bg=Colors.BG_LIGHT)
        right_buttons.pack(side=tk.RIGHT)

        update_btn = ttk.Button(
            right_buttons,
            text="🔄 Update Cursor Server",
            style="Warning.TButton",
            command=self.update_cursor_server,
        )
        update_btn.pack(ipadx=15, ipady=8)

        # Status section
        status_frame = tk.Frame(parent, bg=Colors.BG_LIGHT)
        status_frame.pack(fill=tk.X, pady=(5, 0))

        self.status_label = ttk.Label(
            status_frame, text="✅ Ready", style="MainStatus.TLabel"
        )
        self.status_label.configure(foreground=Colors.SUCCESS)
        self.status_label.pack()

    def create_output_section(self, parent):
        """Create real-time output display section."""
        output_frame = ttk.LabelFrame(
            parent,
            text="  📊 Script Execution Output  ",
            style="MainCard.TLabelframe",
            padding=10,
        )
        output_frame.pack(fill=tk.BOTH, expand=True)

        # Output control header
        control_frame = tk.Frame(output_frame, bg=Colors.BG_CARD)
        control_frame.pack(fill=tk.X, pady=(0, 8))

        # Left side controls
        left_controls = tk.Frame(control_frame, bg=Colors.BG_CARD)
        left_controls.pack(side=tk.LEFT)

        # Clear output button with modern styling
        clear_btn = ttk.Button(
            left_controls,
            text="🗑️ Clear Output",
            style="MainControl.TButton",
            command=self.clear_output,
        )
        clear_btn.pack(side=tk.LEFT, padx=(0, 15), ipadx=10, ipady=4)

        # Auto-scroll checkbox with modern styling
        self.auto_scroll = tk.BooleanVar(value=True)
        scroll_cb = ttk.Checkbutton(
            left_controls, text="🔄 Auto-scroll", variable=self.auto_scroll
        )
        scroll_cb.pack(side=tk.LEFT)

        # Right side - terminal info
        right_controls = tk.Frame(control_frame, bg=Colors.BG_CARD)
        right_controls.pack(side=tk.RIGHT)

        terminal_info = ttk.Label(
            right_controls, text="💻 Terminal Output", style="MainStatus.TLabel"
        )
        terminal_info.configure(foreground=Colors.TEXT_SECONDARY)
        terminal_info.pack()

        # Output text area with modern terminal styling
        text_container = tk.Frame(output_frame, bg=Colors.BG_CARD)
        text_container.pack(fill=tk.BOTH, expand=True)

        # Create modern terminal-style text widget
        self.output_text = tk.Text(
            text_container,
            wrap=tk.WORD,
            font=Fonts.MONOSPACE,
            bg="#1E1E1E",  # Dark terminal background
            fg="#D4D4D4",  # Light gray text
            insertbackground="#FFFFFF",  # White cursor
            selectbackground="#264F78",  # Selection background
            selectforeground="#FFFFFF",  # Selection text
            relief="flat",
            borderwidth=0,
            padx=15,
            pady=10,
        )

        # Modern scrollbar
        scrollbar = ttk.Scrollbar(
            text_container, orient=tk.VERTICAL, command=self.output_text.yview
        )
        self.output_text.configure(yscrollcommand=scrollbar.set)

        # Pack with modern layout
        self.output_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Make output text read-only
        self.output_text.configure(state=tk.DISABLED)

        # Configure text tags for colored output
        self.setup_output_text_tags()

    def setup_output_text_tags(self):
        """Setup text tags for colored terminal output."""
        # Success messages
        self.output_text.tag_configure(
            "success", foreground=Colors.SUCCESS, font=Fonts.MONOSPACE
        )

        # Error messages
        self.output_text.tag_configure(
            "error", foreground=Colors.ERROR, font=Fonts.MONOSPACE
        )

        # Warning messages
        self.output_text.tag_configure(
            "warning", foreground=Colors.WARNING, font=Fonts.MONOSPACE
        )

        # Info messages
        self.output_text.tag_configure(
            "info", foreground=Colors.SECONDARY, font=Fonts.MONOSPACE
        )

        # Command headers
        self.output_text.tag_configure(
            "header", foreground="#61DAFB", font=("Consolas", 11, "bold")
        )

    def logout(self):
        """Return to login page."""
        # Stop any running processes
        if self.current_process:
            try:
                self.current_process.terminate()
            except:
                pass

        # Stop the queue checking
        self.is_running = False

        # Clear any pending after calls
        try:
            self.root.after_cancel(self.after_id)
        except:
            pass

        self.app_controller.show_login_page()

    def connect_cluster(self):
        """Connect to cluster using tunnel.sh script."""
        if self.is_running:
            messagebox.showwarning(
                "Warning", "A connection is already running. Please stop it first."
            )
            return

        try:
            cluster = self.user_info["cluster"]
            username = self.user_info["username"]
            self.append_output(f"=== Connecting to {cluster} using tunnel.sh ===\n")
            self.append_output(f"User: {username}\n")
            self.append_output("=" * 50 + "\n")

            # Update UI state
            self.status_label.config(
                text="🚀 Executing tunnel.sh script...", foreground=Colors.WARNING
            )
            self.connect_btn.config(state=tk.DISABLED)
            self.pls_btn.config(state=tk.DISABLED)
            self.stop_btn.config(state=tk.NORMAL)
            self.is_running = True

            # Build tunnel.sh command with parameters
            tunnel_cmd = ["./tunnel.sh"]

            # Add cluster parameter
            tunnel_cmd.extend(["-a", cluster])

            # Add partition parameter
            tunnel_cmd.extend(["-p", self.param_vars["partition"].get()])

            # Add CPUs parameter
            tunnel_cmd.extend(["-c", self.param_vars["cpus"].get()])

            # Add GPUs parameter
            tunnel_cmd.extend(["-g", self.param_vars["gpus"].get()])

            # Add memory parameter
            tunnel_cmd.extend(["-m", self.param_vars["memory"].get()])

            # Add time parameter
            tunnel_cmd.extend(["-t", self.param_vars["time"].get()])

            # Add node parameter if specified
            if self.param_vars["node"].get():
                tunnel_cmd.extend(["-w", self.param_vars["node"].get()])

            # Add no log flag if enabled
            if self.param_vars["no_log"].get():
                tunnel_cmd.append("-n")

            # Execute in background thread
            thread = threading.Thread(target=self.run_tunnel_script, args=(tunnel_cmd,))
            thread.daemon = True
            thread.start()

        except Exception as e:
            self.append_output(f"Error setting up tunnel.sh execution: {str(e)}\n")
            self.reset_ui_state()

    def run_tunnel_script(self, tunnel_cmd):
        """Run tunnel.sh script in background thread."""
        try:
            # Execute tunnel.sh script
            self.current_process = subprocess.Popen(
                tunnel_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1,
            )

            self.append_output(f"✓ Executing: {' '.join(tunnel_cmd)}\n")

            # Read output line by line in real-time
            while self.current_process and self.current_process.poll() is None:
                try:
                    output = self.current_process.stdout.readline()
                    if output:
                        self.append_output(output)
                except Exception as e:
                    self.append_output(f"Error reading output: {str(e)}\n")
                    break

            # Get return code if process still exists
            if self.current_process:
                return_code = self.current_process.poll()

                if return_code == 0:
                    self.output_queue.put(("status", "success"))
                else:
                    self.output_queue.put(("status", f"error:{return_code}"))

        except Exception as e:
            self.output_queue.put(("status", f"exception:{str(e)}"))
        finally:
            self.current_process = None

    def execute_pls_script(self):
        """Execute pls.sh script."""
        if self.is_running:
            messagebox.showwarning(
                "Warning", "A connection is already running. Please stop it first."
            )
            return

        try:
            # Update UI state
            self.status_label.config(
                text="📊 Executing pls.sh script...", foreground=Colors.WARNING
            )
            self.connect_btn.config(state=tk.DISABLED)
            self.pls_btn.config(state=tk.DISABLED)
            self.stop_btn.config(state=tk.NORMAL)
            self.is_running = True

            self.append_output("=== Executing pls.sh script ===\n")

            # Execute pls.sh script
            pls_cmd = ["./pls.sh", "-a", self.user_info["cluster"]]

            # Execute in background thread
            thread = threading.Thread(target=self.run_pls_script, args=(pls_cmd,))
            thread.daemon = True
            thread.start()

        except Exception as e:
            self.append_output(f"Error executing pls.sh: {str(e)}\n")
            self.reset_ui_state()

    def run_pls_script(self, pls_cmd):
        """Run pls.sh script in background thread."""
        try:
            # Execute pls.sh script
            self.current_process = subprocess.Popen(
                pls_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1,
            )

            self.append_output(f"✓ Executing: {' '.join(pls_cmd)}\n")

            # Read output line by line in real-time
            while self.current_process and self.current_process.poll() is None:
                try:
                    output = self.current_process.stdout.readline()
                    if output:
                        self.append_output(output)
                except Exception as e:
                    self.append_output(f"Error reading output: {str(e)}\n")
                    break

            # Get return code if process still exists
            if self.current_process:
                return_code = self.current_process.poll()

                if return_code == 0:
                    self.output_queue.put(("status", "success"))
                else:
                    self.output_queue.put(("status", f"error:{return_code}"))

        except Exception as e:
            self.output_queue.put(("status", f"exception:{str(e)}"))
        finally:
            self.current_process = None

    def update_cursor_server(self):
        """Execute cursor server update command."""
        if self.is_running:
            messagebox.showwarning(
                "Warning", "A connection is already running. Please stop it first."
            )
            return

        try:
            # Update UI state
            self.status_label.config(
                text="🔄 Updating cursor server...", foreground=Colors.WARNING
            )
            self.connect_btn.config(state=tk.DISABLED)
            self.pls_btn.config(state=tk.DISABLED)
            self.stop_btn.config(state=tk.NORMAL)
            self.is_running = True

            self.append_output("=== Updating Cursor Server ===\n")

            # Execute update_tunnel.sh script
            update_cmd = ["./update_tunnel.sh"]

            # Execute in background thread
            thread = threading.Thread(target=self.run_update_script, args=(update_cmd,))
            thread.daemon = True
            thread.start()

        except Exception as e:
            self.append_output(f"Error setting up cursor server update: {str(e)}\n")
            self.reset_ui_state()

    def run_update_script(self, update_cmd):
        """Run update_code.sh script in background thread."""
        try:
            # Execute update_code.sh script
            self.current_process = subprocess.Popen(
                update_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1,
            )

            self.append_output(f"✓ Executing: {' '.join(update_cmd)}\n")

            # Read output line by line in real-time
            while self.current_process and self.current_process.poll() is None:
                try:
                    output = self.current_process.stdout.readline()
                    if output:
                        self.append_output(output)
                except Exception as e:
                    self.append_output(f"Error reading output: {str(e)}\n")
                    break

            # Get return code if process still exists
            if self.current_process:
                return_code = self.current_process.poll()

                if return_code == 0:
                    self.output_queue.put(("status", "update_success"))
                else:
                    self.output_queue.put(("status", f"update_error:{return_code}"))

        except Exception as e:
            self.output_queue.put(("status", f"exception:{str(e)}"))
        finally:
            self.current_process = None

    def stop_command(self):
        """Stop the currently running command."""
        # Stop tunnel.sh process if running
        if self.current_process:
            try:
                self.current_process.terminate()
                self.append_output("\n=== ⏹️ Script execution stopped by user ===\n")
                self.status_label.config(
                    text="⏹️ Script stopped", foreground=Colors.ERROR
                )
            except Exception as e:
                self.append_output(f"\n❌ Error stopping script: {str(e)}\n")

        self.reset_ui_state()

    def reset_ui_state(self):
        """Reset UI state after command completion."""
        self.is_running = False
        self.connect_btn.config(state=tk.NORMAL)
        self.pls_btn.config(state=tk.NORMAL)
        self.stop_btn.config(state=tk.DISABLED)
        self.current_process = None

    def check_queue(self):
        """Check output queue and update display."""
        # Check if the page is still active
        if not hasattr(self, "status_label") or not self.status_label.winfo_exists():
            return

        try:
            while True:
                msg_type, msg_content = self.output_queue.get_nowait()

                if msg_type == "output":
                    self.append_output(msg_content)
                elif msg_type == "status":
                    if msg_content == "success":
                        self.status_label.config(
                            text="✅ Script completed successfully",
                            foreground=Colors.SUCCESS,
                        )
                        self.append_output(
                            "\n=== ✅ Script completed successfully ===\n"
                        )
                    elif msg_content == "update_success":
                        self.status_label.config(
                            text="✅ Cursor server updated successfully",
                            foreground=Colors.SUCCESS,
                        )
                        self.append_output(
                            "\n=== ✅ Cursor server update completed successfully ===\n"
                        )
                    elif msg_content.startswith("error:"):
                        return_code = msg_content.split(":", 1)[1]
                        self.status_label.config(
                            text=f"❌ Script failed (exit code: {return_code})",
                            foreground=Colors.ERROR,
                        )
                        self.append_output(
                            f"\n=== ❌ Script failed with exit code: {return_code} ===\n"
                        )
                    elif msg_content.startswith("update_error:"):
                        return_code = msg_content.split(":", 1)[1]
                        self.status_label.config(
                            text=f"❌ Cursor server update failed (exit code: {return_code})",
                            foreground=Colors.ERROR,
                        )
                        self.append_output(
                            f"\n=== ❌ Cursor server update failed with exit code: {return_code} ===\n"
                        )
                    elif msg_content.startswith("exception:"):
                        error = msg_content.split(":", 1)[1]
                        self.status_label.config(
                            text="❌ Script execution error", foreground=Colors.ERROR
                        )
                        self.append_output(f"\n=== ❌ Error: {error} ===\n")

                    self.reset_ui_state()

        except queue.Empty:
            pass
        except tk.TclError:
            # Widget has been destroyed, stop checking
            return

        # Schedule next check only if still active
        if hasattr(self, "status_label") and self.status_label.winfo_exists():
            self.after_id = self.root.after(100, self.check_queue)

    def append_output(self, text):
        """
        Append text to output display.

        Args:
            text (str): Text to append
        """
        self.output_text.configure(state=tk.NORMAL)
        self.output_text.insert(tk.END, text)
        self.output_text.configure(state=tk.DISABLED)

        # Auto-scroll to bottom if enabled
        if self.auto_scroll.get():
            self.output_text.see(tk.END)

    def clear_output(self):
        """Clear the output display."""
        self.output_text.configure(state=tk.NORMAL)
        self.output_text.delete(1.0, tk.END)
        self.output_text.configure(state=tk.DISABLED)


class ClusterManagerApp:
    """
    Application controller managing page transitions and state.

    Handles:
    - Page switching between login and main functionality
    - User session management
    - Application initialization and cleanup
    """

    def __init__(self):
        """Initialize the application."""
        self.root = tk.Tk()
        self.current_page = None

        # Show login page initially
        self.show_login_page()

    def show_login_page(self):
        """Display the login page."""
        self.current_page = LoginPage(self.root, self)

    def show_main_page(self, user_info):
        """Display the main functionality page."""
        self.current_page = MainPage(self.root, self, user_info)

    def run(self):
        """Start the application main loop."""
        self.root.mainloop()


def main():
    """Main function to run the GUI application."""
    app = ClusterManagerApp()
    app.run()


if __name__ == "__main__":
    main()
